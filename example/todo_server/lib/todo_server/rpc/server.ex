defmodule TodoServer.Rpc.Server do
  @moduledoc """
  Server-side RPC core: parses `/rpc/run` and `/rpc/validate` requests, executes
  the Ash action, and formats the response envelope. The shared protocol core
  (this + `Fields`) speaks the same wire protocol `ash_remote` consumes.
  """

  alias TodoServer.Rpc.Fields

  @domains [TodoServer.Domain]

  def run(params) do
    with {:ok, resource} <- resolve_resource(params["resource"]),
         {:ok, action} <- resolve_action(resource, params["action"]) do
      %{"success" => true, "data" => dispatch(resource, action, params)}
    end
    |> normalize()
  end

  def validate(params) do
    with {:ok, resource} <- resolve_resource(params["resource"]),
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

  defp get?(action, params), do: Map.get(action, :get?, false) or not is_nil(params["primary_key"])

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
      _ -> []
    end)
  end

  defp maybe(subject, _fun, nil), do: subject
  defp maybe(subject, fun, arg), do: fun.(subject, arg)

  defp resolve_resource(nil), do: {:error, :missing_resource}

  defp resolve_resource(module_string) when is_binary(module_string) do
    module = Module.concat([module_string])
    if module in all_resources(), do: {:ok, module}, else: {:error, {:unknown_resource, module_string}}
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

  defp all_resources, do: Enum.flat_map(@domains, &Ash.Domain.Info.resources/1)

  defp valid?(%Ash.Changeset{valid?: valid?}), do: valid?
  defp valid?(%Ash.Query{valid?: valid?}), do: valid?
  defp errors_of(%{errors: errors}), do: errors

  # --- error handling ------------------------------------------------------

  defp normalize(%{} = envelope), do: envelope
  defp normalize({:error, reason}), do: %{"success" => false, "errors" => to_errors(reason)}

  defp to_errors(errors) when is_list(errors), do: Enum.flat_map(errors, &to_errors/1)
  defp to_errors({:unknown_resource, r}), do: [%{"type" => "unknown_resource", "message" => "Unknown resource: #{r}"}]
  defp to_errors({:unknown_action, a}), do: [%{"type" => "unknown_action", "message" => "Unknown action: #{a}"}]
  defp to_errors(:missing_resource), do: [%{"type" => "invalid", "message" => "Missing resource"}]
  defp to_errors(:missing_action), do: [%{"type" => "invalid", "message" => "Missing action"}]

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
