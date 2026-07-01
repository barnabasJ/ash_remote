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

  @doc "All resources exposed for an OTP app (every resource in its domains)."
  def resources(otp_app) do
    otp_app |> Ash.Info.domains() |> Enum.flat_map(&Ash.Domain.Info.resources/1)
  end

  @doc """
  Generate the exposed surface as a JSON `Ash.Info.Manifest`.

  With no `entrypoints`, every public action of the app's domains is included —
  the same surface the RPC router exposes. Pass explicit `{resource, action}`
  entrypoints to restrict it.
  """
  def manifest_json(otp_app, entrypoints \\ nil) do
    opts = [otp_app: otp_app]
    opts = if entrypoints, do: Keyword.put(opts, :action_entrypoints, entrypoints), else: opts
    {:ok, spec} = Ash.Info.Manifest.generate(opts)
    {:ok, json} = Ash.Info.Manifest.JsonSerializer.to_json(spec, pretty: true)
    json
  end

  @doc "Run an action against the exposed resources. Returns the response envelope."
  def run_action(otp_app, params) do
    with {:ok, resource} <- resolve_resource(otp_app, params["resource"]),
         {:ok, action} <- resolve_action(resource, params["action"]) do
      %{"success" => true, "data" => dispatch(resource, action, params)}
    end
    |> normalize()
  rescue
    error -> %{"success" => false, "errors" => to_errors(error)}
  end

  @doc "Validate an action's input without executing. Returns the response envelope."
  def validate_action(otp_app, params) do
    with {:ok, resource} <- resolve_resource(otp_app, params["resource"]),
         {:ok, action} <- resolve_action(resource, params["action"]) do
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
        %{results: results} -> Fields.serialize(results, resource, fields)
        results -> Fields.serialize(results, resource, fields)
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

  defp resolve_action(resource, name) when is_binary(name) do
    case Ash.Resource.Info.action(resource, String.to_existing_atom(name)) do
      nil -> {:error, {:unknown_action, name}}
      action -> {:ok, action}
    end
  rescue
    ArgumentError -> {:error, {:unknown_action, name}}
  end

  defp resolve_action(_resource, _), do: {:error, :missing_action}

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
    case mod |> Module.split() |> List.last() do
      "Forbidden" -> "forbidden"
      "NotFound" -> "not_found"
      "Required" -> "required"
      "InvalidAttribute" -> "invalid"
      other -> Macro.underscore(other)
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
