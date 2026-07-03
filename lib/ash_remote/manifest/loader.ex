defmodule AshRemote.Manifest.Loader do
  @moduledoc """
  Loads a manifest from a file path or URL, validates its `schema_version`, and
  normalizes the JSON into `AshRemote.Manifest.*` structs. Tolerant of unknown
  fields.
  """

  alias AshRemote.Manifest
  alias AshRemote.Manifest.{Action, Argument, Field, Relationship, Resource, Type, Validation}

  @supported_major "1"

  @doc "Load and normalize a manifest from a path or http(s) URL."
  @spec load(String.t(), keyword()) :: {:ok, Manifest.t()} | {:error, term()}
  def load(source, opts \\ []) do
    with {:ok, raw} <- read(source),
         {:ok, json} <- decode(raw),
         :ok <- validate_version(json, opts) do
      {:ok, normalize(json)}
    end
  end

  @doc "Like `load/2` but raises on error."
  def load!(source, opts \\ []) do
    case load(source, opts) do
      {:ok, manifest} -> manifest
      {:error, reason} -> raise "failed to load manifest: #{inspect(reason)}"
    end
  end

  # --- read / decode / validate -------------------------------------------

  defp read("http://" <> _ = url), do: fetch(url)
  defp read("https://" <> _ = url), do: fetch(url)

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:read_error, path, reason}}
    end
  end

  defp fetch(url) do
    case Req.get(url) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, Jason.encode!(body)}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, {:transport_error, reason}}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp validate_version(json, opts) do
    version = json["schema_version"] || ""
    expected = Keyword.get(opts, :expected_major, @supported_major)

    case String.split(version, ".") do
      [^expected | _] -> :ok
      _ -> {:error, {:unsupported_schema_version, version}}
    end
  end

  # --- normalize -----------------------------------------------------------

  defp normalize(json) do
    actions_by_resource = actions_by_resource(json["entrypoints"] || [])

    resources =
      (json["resources"] || [])
      |> Enum.map(&normalize_resource(&1, actions_by_resource))
      |> Map.new(fn resource -> {resource.module, resource} end)

    types =
      (json["types"] || [])
      |> Enum.map(&normalize_type/1)
      |> Enum.reject(&is_nil(&1.module))
      |> Map.new(fn type -> {type.module, type} end)

    %Manifest{
      schema_version: json["schema_version"],
      resources: resources,
      types: types,
      filter_capabilities: json["filter_capabilities"] || %{},
      sort_capabilities: json["sort_capabilities"] || %{}
    }
  end

  defp actions_by_resource(entrypoints) do
    entrypoints
    |> Enum.map(&normalize_entrypoint/1)
    |> Enum.group_by(fn {resource, _action} -> resource end, fn {_r, action} -> action end)
  end

  defp normalize_entrypoint(%{"resource" => resource, "action" => action}) do
    {resource, normalize_action(action)}
  end

  defp normalize_resource(resource, actions_by_resource) do
    module = resource["module"]

    %Resource{
      name: resource["name"],
      module: module,
      embedded?: resource["embedded"] || false,
      description: resource["description"],
      primary_key: Enum.map(resource["primary_key"] || [], &atom/1),
      fields: normalize_fields(resource["fields"] || %{}),
      relationships: normalize_relationships(resource["relationships"] || %{}),
      identities: normalize_identities(resource["identities"] || %{}),
      validations: normalize_validations(resource["validations"] || []),
      multitenancy: resource["multitenancy"],
      actions: Map.get(actions_by_resource, module, [])
    }
  end

  defp normalize_validations(validations) do
    Enum.map(validations, fn validation ->
      %Validation{
        module: validation["module"],
        opts: validation["opts"],
        on: Enum.map(validation["on"] || [], &atom/1),
        where:
          Enum.map(validation["where"] || [], fn condition ->
            %{module: condition["module"], opts: condition["opts"]}
          end),
        message: validation["message"],
        only_when_valid?: validation["only_when_valid"] || false
      }
    end)
  end

  defp normalize_fields(fields) do
    Map.new(fields, fn {name, field} ->
      {name, normalize_field(name, field)}
    end)
  end

  defp normalize_field(name, field) do
    %Field{
      name: name,
      kind: atom(field["kind"]),
      type: normalize_type(field["type"]),
      aggregate_kind: atom(field["aggregate_kind"]),
      description: field["description"],
      allow_nil?: field["allow_nil"],
      writable?: field["writable"] || false,
      has_default?: field["has_default"] || false,
      filterable?: field["filterable"] || false,
      sortable?: field["sortable"] || false,
      primary_key?: field["primary_key"] || false,
      sensitive?: field["sensitive"] || false,
      select_by_default?: Map.get(field, "select_by_default", true),
      expression: field["expression"],
      arguments: normalize_arguments(field["arguments"]),
      filter_operators: normalize_applicable(field["filter_operators"]),
      filter_functions: normalize_applicable(field["filter_functions"])
    }
  end

  defp normalize_applicable(nil), do: []

  defp normalize_applicable(list) when is_list(list) do
    Enum.map(list, fn %{"name" => name} = entry -> %{name: name, rhs: entry["rhs"]} end)
  end

  defp normalize_type(nil), do: nil

  defp normalize_type(type) do
    %Type{
      kind: atom(type["kind"]),
      name: type["name"],
      module: type["module"],
      values: type["values"],
      constraints: type["constraints"],
      item_type: normalize_type(type["item_type"]),
      instance_of: type["instance_of"]
    }
  end

  defp normalize_relationships(relationships) do
    Map.new(relationships, fn {name, rel} ->
      {name,
       %Relationship{
         name: name,
         type: atom(rel["type"]),
         cardinality: atom(rel["cardinality"]),
         destination: rel["destination"],
         description: rel["description"],
         source_attribute: atom(rel["source_attribute"]),
         destination_attribute: atom(rel["destination_attribute"]),
         allow_nil?: rel["allow_nil"]
       }}
    end)
  end

  defp normalize_identities(identities) do
    Map.new(identities, fn {name, %{"keys" => keys}} ->
      {name, Enum.map(keys, &atom/1)}
    end)
  end

  defp normalize_action(action) do
    %Action{
      name: action["name"],
      type: atom(action["type"]),
      primary?: action["primary"] || false,
      get?: action["get"] || false,
      returns: normalize_type(action["returns"]),
      pagination: action["pagination"],
      inputs: normalize_arguments(action["inputs"])
    }
  end

  defp normalize_arguments(nil), do: []

  defp normalize_arguments(list) when is_list(list) do
    Enum.map(list, fn arg ->
      %Argument{
        name: arg["name"],
        type: normalize_type(arg["type"]),
        allow_nil?: arg["allow_nil"],
        has_default?: arg["has_default"] || false,
        required?: arg["required"] || false
      }
    end)
  end

  defp atom(nil), do: nil
  defp atom(value) when is_atom(value), do: value
  defp atom(value) when is_binary(value), do: String.to_atom(value)
end
