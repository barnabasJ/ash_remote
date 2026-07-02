defmodule AshRemote.Server do
  @moduledoc """
  Server-side RPC core for the `ash_remote` protocol.

  Ported from `ash_typescript`'s RPC pipeline and kept in `ash_remote` so a
  backend can serve the exact protocol `ash_remote` clients speak, without a hard
  dependency on `ash_typescript`. This is the "shared protocol core" that would
  later be extracted into a package used by both.

  Mount it with `AshRemote.Server.Router` (a Plug). These functions are transport
  agnostic — give them the OTP app whose domains are exposed and the decoded
  request params.

      %{"resource" => module_string, "action" => action_name, "fields" => [...],
        "input" => %{...}, "filter" => %{...}, "sort" => "...", "page" => %{...},
        "primary_key" => %{...}}
      => %{"success" => true, "data" => ...}
       | %{"success" => false, "errors" => [%{"type","message","path"}]}

  Actions are addressed by `{resource, action}` (both present in the manifest),
  since the manifest does not serialize an opaque RPC name.
  """

  alias AshRemote.Server.Fields

  @doc "The exposed `{resource, action}` entrypoints across an OTP app's `AshRemote.Rpc` domains."
  def entrypoints(otp_app) do
    otp_app
    |> Ash.Info.domains()
    |> Enum.filter(&AshRemote.Rpc.Info.rpc?/1)
    |> Enum.flat_map(&AshRemote.Rpc.Info.entrypoints/1)
  end

  @doc "Resources that have at least one exposed action."
  def resources(otp_app) do
    otp_app |> entrypoints() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end

  @doc "Generate the exposed surface as a JSON `Ash.Info.Manifest` (exactly the `rpc do` block)."
  def manifest_json(otp_app) do
    {:ok, spec} =
      Ash.Info.Manifest.generate(otp_app: otp_app, action_entrypoints: entrypoints(otp_app))

    spec |> manifest_map() |> Jason.encode!(pretty: true)
  end

  # Ash's JsonSerializer (through at least 3.29.3) omits the action `name` from
  # serialized entrypoints, but the %Manifest{} struct carries it — inject it so
  # the client knows which action to call. (Candidate upstream fix.)
  defp manifest_map(spec) do
    map = Ash.Info.Manifest.JsonSerializer.to_map(spec)

    entrypoints =
      map
      |> Map.get("entrypoints", [])
      |> Enum.zip(spec.entrypoints)
      |> Enum.map(fn {entry, %{action: action}} ->
        update_in(entry, ["action"], &Map.put(&1, "name", to_string(action.name)))
      end)

    Map.put(map, "entrypoints", entrypoints)
  end

  @doc "Run an action against the exposed resources. Returns the response envelope."
  def run_action(otp_app, params) do
    with {:ok, resource} <- resolve_resource(otp_app, params["resource"]),
         {:ok, action} <- resolve_action(otp_app, resource, params["action"]) do
      %{"success" => true, "data" => dispatch(resource, action, params)}
    end
    |> normalize()
  rescue
    error -> %{"success" => false, "errors" => to_errors(error)}
  end

  @doc "Validate an action's input without executing. Returns the response envelope."
  def validate_action(otp_app, params) do
    with {:ok, resource} <- resolve_resource(otp_app, params["resource"]),
         {:ok, action} <- resolve_action(otp_app, resource, params["action"]) do
      input = params["input"] || %{}

      subject =
        case action.type do
          :read -> Ash.Query.for_read(resource, action.name, input)
          :create -> Ash.Changeset.for_create(resource, action.name, input)
          :update -> resource |> struct() |> Ash.Changeset.for_update(action.name, input)
          :destroy -> resource |> struct() |> Ash.Changeset.for_destroy(action.name, input)
        end

      errors = if valid?(subject), do: [], else: to_errors(errors_of(subject))
      %{"success" => errors == [], "errors" => errors}
    end
    |> normalize()
  rescue
    error -> %{"success" => false, "errors" => to_errors(error)}
  end

  # --- dispatch ------------------------------------------------------------

  defp dispatch(resource, %{type: :read} = action, params) do
    fields = params["fields"] || []
    {select, load} = Fields.to_select_and_load(resource, fields)
    input = Map.merge(params["input"] || %{}, params["primary_key"] || %{})

    query =
      resource
      |> Ash.Query.for_read(action.name, input)
      |> maybe(&Ash.Query.filter_input/2, params["filter"])
      |> maybe(&Ash.Query.sort_input/2, params["sort"])
      |> Ash.Query.select(select)
      |> Ash.Query.load(load)
      |> maybe(&Ash.Query.page/2, page_opts(params["page"]))

    if get?(action, params) do
      query |> Ash.read_one!() |> then(&Fields.serialize(&1, resource, fields))
    else
      case Ash.read!(query) do
        %{results: results} = page ->
          %{
            "results" => Fields.serialize(results, resource, fields),
            "count" => Map.get(page, :count),
            "type" => page.__struct__ |> Module.split() |> List.last() |> String.downcase()
          }

        results ->
          Fields.serialize(results, resource, fields)
      end
    end
  end

  defp dispatch(resource, %{type: :create} = action, params) do
    fields = params["fields"] || []
    {_select, load} = Fields.to_select_and_load(resource, fields)

    resource
    |> Ash.Changeset.for_create(action.name, params["input"] || %{})
    |> Ash.create!(load: load)
    |> then(&Fields.serialize(&1, resource, fields))
  end

  defp dispatch(resource, %{type: :update} = action, params) do
    fields = params["fields"] || []
    {_select, load} = Fields.to_select_and_load(resource, fields)

    resource
    |> fetch!(params["primary_key"])
    |> Ash.Changeset.for_update(action.name, params["input"] || %{})
    |> Ash.update!(load: load)
    |> then(&Fields.serialize(&1, resource, fields))
  end

  defp dispatch(resource, %{type: :destroy} = action, params) do
    resource
    |> fetch!(params["primary_key"])
    |> Ash.Changeset.for_destroy(action.name, params["input"] || %{})
    |> Ash.destroy!()

    %{}
  end

  # --- helpers -------------------------------------------------------------

  defp get?(action, params),
    do: Map.get(action, :get?, false) or not is_nil(params["primary_key"])

  defp fetch!(resource, primary_key) when is_map(primary_key) do
    key = Map.new(primary_key, fn {k, v} -> {String.to_existing_atom(to_string(k)), v} end)
    Ash.get!(resource, key)
  end

  defp page_opts(nil), do: nil

  defp page_opts(page) when is_map(page) do
    opts =
      Enum.flat_map(page, fn
        {"limit", v} -> [limit: v]
        {"offset", v} -> [offset: v]
        {"count", v} -> [count: v]
        _ -> []
      end)

    if opts == [], do: nil, else: opts
  end

  defp maybe(subject, _fun, nil), do: subject
  defp maybe(subject, fun, arg), do: fun.(subject, arg)

  defp resolve_resource(_otp_app, nil), do: {:error, :missing_resource}

  defp resolve_resource(otp_app, module_string) when is_binary(module_string) do
    module = Module.concat([module_string])

    if module in resources(otp_app),
      do: {:ok, module},
      else: {:error, {:unknown_resource, module_string}}
  end

  defp resolve_action(otp_app, resource, name) when is_binary(name) do
    action_name = String.to_existing_atom(name)

    cond do
      {resource, action_name} not in entrypoints(otp_app) -> {:error, {:unknown_action, name}}
      action = Ash.Resource.Info.action(resource, action_name) -> {:ok, action}
      true -> {:error, {:unknown_action, name}}
    end
  rescue
    ArgumentError -> {:error, {:unknown_action, name}}
  end

  defp resolve_action(_otp_app, _resource, _), do: {:error, :missing_action}

  defp valid?(%Ash.Changeset{valid?: valid?}), do: valid?
  defp valid?(%Ash.Query{valid?: valid?}), do: valid?
  defp errors_of(%{errors: errors}), do: errors

  # --- error handling ------------------------------------------------------

  defp normalize(%{} = envelope), do: envelope
  defp normalize({:error, reason}), do: %{"success" => false, "errors" => to_errors(reason)}

  defp to_errors(errors) when is_list(errors), do: Enum.flat_map(errors, &to_errors/1)

  defp to_errors({:unknown_resource, r}),
    do: [%{"type" => "unknown_resource", "message" => "Unknown resource: #{r}"}]

  defp to_errors({:unknown_action, a}),
    do: [%{"type" => "unknown_action", "message" => "Unknown action: #{a}"}]

  defp to_errors(:missing_resource),
    do: [%{"type" => "invalid", "message" => "Missing resource"}]

  defp to_errors(:missing_action),
    do: [%{"type" => "invalid", "message" => "Missing action"}]

  defp to_errors(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [error])
    |> Enum.map(&format_error/1)
  end

  defp format_error(error) do
    %{
      "type" => error_type(error),
      "message" => safe_message(error),
      "path" => error |> path() |> Enum.map(&to_string/1)
    }
  end

  defp error_type(%mod{}) do
    segments = Module.split(mod)

    cond do
      "Forbidden" in segments -> "forbidden"
      List.last(segments) == "NotFound" -> "not_found"
      List.last(segments) == "Required" -> "required"
      List.last(segments) == "InvalidAttribute" -> "invalid"
      true -> segments |> List.last() |> Macro.underscore()
    end
  end

  defp error_type(_), do: "unknown"

  defp path(%{path: path}) when is_list(path), do: path
  defp path(%{field: field}) when not is_nil(field), do: [field]
  defp path(_), do: []

  defp safe_message(error) do
    Exception.message(error)
  rescue
    _ -> inspect(error)
  end
end
