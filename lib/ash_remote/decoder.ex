defmodule AshRemote.Decoder do
  @moduledoc """
  Turns wire records (string-keyed maps from an `ash_remote` RPC or notification
  payload) back into partially-loaded resource structs.

  Extracted from `AshRemote.DataLayer` so the realtime subscriber
  (`AshRemote.Realtime.Inbound`) can reconstruct records from pushed
  notification payloads through the exact same decode path the HTTP data layer
  uses for RPC responses.
  """

  @doc """
  The full-record decode plan for a resource: `{wire_fields, plan}` where
  `wire_fields` is the list of string field names to request and `plan` maps each
  wire key to a `{:attribute, name}` decode target. Covers every public attribute
  plus the primary key — the same set a write echoes back and a notification
  payload carries.
  """
  def write_fields(resource) do
    names = resource |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)
    names = Enum.uniq(Ash.Resource.Info.primary_key(resource) ++ names)
    {Enum.map(names, &to_string/1), Enum.map(names, &{to_string(&1), {:attribute, &1}})}
  end

  @doc ~S'Decode a list (or `%{"results" => [...]}`) of wire records via `plan`.'
  def decode_records(%{"results" => results}, resource, plan) do
    Enum.map(results, &decode_record(&1, resource, plan))
  end

  def decode_records(records, resource, plan) when is_list(records) do
    Enum.map(records, &decode_record(&1, resource, plan))
  end

  @doc "Decode a single wire record (string-keyed map) into a loaded struct via `plan`."
  def decode_record(nil, _resource, _plan), do: nil

  def decode_record(map, resource, plan) when is_map(map) do
    record = struct(resource)

    record =
      Enum.reduce(plan, record, fn {wire_key, target}, acc ->
        value = Map.get(map, wire_key)
        place(acc, target, value, resource)
      end)

    %{record | __meta__: %Ecto.Schema.Metadata{state: :loaded, schema: resource}}
  end

  defp place(record, {:attribute, name}, value, resource) do
    Map.put(record, name, cast_attribute(resource, name, value))
  end

  defp place(record, {:remote_calc_meta, name}, value, resource) do
    Ash.Resource.put_metadata(
      record,
      {:ash_remote_calc, name},
      cast_calculation(resource, name, value)
    )
  end

  defp place(record, {:calculation, %{load: load} = calc}, value, _resource)
       when not is_nil(load) do
    Map.put(record, calc.load, value)
  end

  defp place(record, {:calculation, calc}, value, _resource) do
    Map.update!(record, :calculations, &Map.put(&1, calc.name, value))
  end

  defp place(record, {:aggregate, %{load: load} = _agg}, value, _resource)
       when not is_nil(load) do
    Map.put(record, load, value)
  end

  defp place(record, {:aggregate, agg}, value, _resource) do
    Map.update!(record, :aggregates, &Map.put(&1, agg.name, value))
  end

  @doc "Cast a wire value to an attribute's Ash type, falling back to the raw value."
  def cast_attribute(resource, name, value) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil ->
        value

      attr ->
        case Ash.Type.cast_input(attr.type, value, attr.constraints) do
          {:ok, casted} -> casted
          _ -> value
        end
    end
  end

  @doc "Cast a wire value to a calculation's Ash type, falling back to the raw value."
  def cast_calculation(resource, name, value) do
    case Ash.Resource.Info.calculation(resource, name) do
      %{type: type, constraints: constraints} ->
        case Ash.Type.cast_input(type, value, constraints) do
          {:ok, cast} -> cast
          _ -> value
        end

      _ ->
        value
    end
  end
end
