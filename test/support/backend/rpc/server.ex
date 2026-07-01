defmodule AshRemote.Backend.Rpc.Server do
  @moduledoc """
  Ported (template) server-side RPC core for the reference backend.

  Speaks the `ash_typescript`-style wire protocol, structurally:

      request  = %{"resource" => module_string, "action" => action_name,
                   "fields" => [...], "input" => %{...},
                   "filter" => %{...}, "sort" => "...", "page" => %{...},
                   "primary_key" => %{...}}
      response = %{"success" => true, "data" => ...}
               | %{"success" => false, "errors" => [%{"type","message","path"}]}

  Actions are identified by `{resource, action}` (both present in the manifest)
  rather than a single opaque RPC name, because the manifest does not serialize
  RPC names. Written dependency-free so it can be extracted later.
  """

  alias AshRemote.Backend.Rpc.Fields

  @domains [AshRemote.Backend.Domain]

  @doc "Run an action. Returns the response envelope map."
  def run(params) do
    with {:ok, resource} <- resolve_resource(params["resource"]),
         {:ok, action} <- resolve_action(resource, params["action"]) do
      data = dispatch(resource, action, params)
      %{"success" => true, "data" => data}
    end
    |> handle_errors()
  end

  @doc "Validate action input without executing. Returns the response envelope map."
  def validate(params) do
    with {:ok, resource} <- resolve_resource(params["resource"]),
         {:ok, action} <- resolve_action(resource, params["action"]) do
      input = params["input"] || %{}

      changeset_or_query =
        case action.type do
          :read ->
            Ash.Query.for_read(resource, action.name, input)

          :create ->
            Ash.Changeset.for_create(resource, action.name, input)

          :update ->
            resource |> blank() |> Ash.Changeset.for_update(action.name, input)

          :destroy ->
            resource |> blank() |> Ash.Changeset.for_destroy(action.name, input)
        end

      errors = validation_errors(changeset_or_query)
      %{"success" => errors == [], "errors" => errors}
    end
    |> handle_errors()
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
        %{results: results} = page -> paginated(page, results, resource, fields)
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

  defp paginated(page, results, resource, fields) do
    %{
      "results" => Fields.serialize(results, resource, fields),
      "count" => Map.get(page, :count),
      "type" => page.__struct__ |> Module.split() |> List.last() |> String.downcase()
    }
  end

  defp get?(action, params) do
    Map.get(action, :get?, false) or not is_nil(params["primary_key"])
  end

  defp fetch!(resource, primary_key) when is_map(primary_key) do
    key = Map.new(primary_key, fn {k, v} -> {String.to_existing_atom(to_string(k)), v} end)
    Ash.get!(resource, key)
  end

  defp page_opts(nil), do: nil

  defp page_opts(page) when is_map(page) do
    Enum.flat_map(page, fn
      {"limit", v} -> [limit: v]
      {"offset", v} -> [offset: v]
      {"count", v} -> [count: v]
      {"keyset", v} when is_binary(v) -> [after: v]
      _ -> []
    end)
  end

  defp maybe(subject, _fun, nil), do: subject
  defp maybe(subject, fun, arg), do: fun.(subject, arg)

  defp blank(resource), do: struct(resource)

  defp resolve_resource(nil), do: {:error, :missing_resource}

  defp resolve_resource(module_string) when is_binary(module_string) do
    module = Module.concat([module_string])

    if module in all_resources() do
      {:ok, module}
    else
      {:error, {:unknown_resource, module_string}}
    end
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

  defp all_resources do
    Enum.flat_map(@domains, &Ash.Domain.Info.resources/1)
  end

  defp validation_errors(%Ash.Changeset{} = changeset) do
    if changeset.valid?, do: [], else: to_errors(changeset.errors)
  end

  defp validation_errors(%Ash.Query{} = query) do
    if query.valid?, do: [], else: to_errors(query.errors)
  end

  # --- error handling ------------------------------------------------------

  defp handle_errors(%{} = envelope), do: envelope

  defp handle_errors({:error, reason}) do
    %{"success" => false, "errors" => to_errors(reason)}
  end

  def rescue_run(params) do
    run(params)
  rescue
    error -> %{"success" => false, "errors" => to_errors(error)}
  end

  def rescue_validate(params) do
    validate(params)
  rescue
    error -> %{"success" => false, "errors" => to_errors(error)}
  end

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
      "InvalidAttribute" -> "invalid"
      "Required" -> "required"
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
