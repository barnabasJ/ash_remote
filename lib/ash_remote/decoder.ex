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

  @doc ~S"""
  Decode a list (or `%{"results" => [...]}`) of wire records via `plan` into
  `{:ok, [record]}` — the shape `Ash.DataLayer.run_query/2` must return
  regardless of whether the underlying read was `get?`-style (Ash core does
  its own get?-arity validation on the returned list afterward).

  `opts[:get?]` (default `false`) — whether this read's action is declared
  `get?: true` (or `get_by`, which implies it), the same signal
  `AshRemote.Server`'s dispatch uses to decide the response shape (M11):

    * a bare single object or explicit `nil` is legitimate ONLY for a
      `get?` read (a hit decodes to a one-element list; a miss to `[]`);
    * for an ordinary (non-`get?`) read, a bare object or `nil` is a
      protocol violation (a list read must always get a list, `[]` for no
      rows) — never silently accepted, always a typed `{:error, _}`
      (`parse_run`'s own malformed-response case, `%{"success" => true}`
      with no `data` key, is caught earlier and never reaches here).

  Never raises — a malformed or malicious server response degrades to a
  typed error instead of crashing the caller.
  """
  @spec decode_records(term(), module(), list(), keyword()) ::
          {:ok, [struct()]} | {:error, [map()]}
  def decode_records(data, resource, plan, opts \\ [])

  def decode_records(%{"results" => results}, resource, plan, _opts) when is_list(results) do
    {:ok, Enum.map(results, &decode_record(&1, resource, plan))}
  end

  def decode_records(records, resource, plan, _opts) when is_list(records) do
    {:ok, Enum.map(records, &decode_record(&1, resource, plan))}
  end

  def decode_records(nil, _resource, _plan, opts) do
    if Keyword.get(opts, :get?, false) do
      {:ok, []}
    else
      {:error,
       [
         %{
           "type" => "framework",
           "message" => "expected a list response for a non-get? read, got an explicit null"
         }
       ]}
    end
  end

  def decode_records(map, resource, plan, opts) when is_map(map) do
    if Keyword.get(opts, :get?, false) do
      {:ok, [decode_record(map, resource, plan)]}
    else
      {:error,
       [
         %{
           "type" => "framework",
           "message" =>
             "expected a list response for a non-get? read, got a single object: #{inspect(map)}"
         }
       ]}
    end
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
    Map.put(record, calc.load, cast_typed(calc.type, calc.constraints, value))
  end

  defp place(record, {:calculation, calc}, value, _resource) do
    Map.update!(
      record,
      :calculations,
      &Map.put(&1, calc.name, cast_typed(calc.type, calc.constraints, value))
    )
  end

  defp place(record, {:aggregate, %{load: load} = agg}, value, _resource)
       when not is_nil(load) do
    Map.put(record, load, cast_typed(agg.type, agg.constraints, value))
  end

  defp place(record, {:aggregate, agg}, value, _resource) do
    Map.update!(
      record,
      :aggregates,
      &Map.put(&1, agg.name, cast_typed(agg.type, agg.constraints, value))
    )
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
      %{type: type, constraints: constraints} -> cast_typed(type, constraints, value)
      _ -> value
    end
  end

  # M7: query-plan calculations/aggregates (Ash.Query.Calculation /
  # Ash.Query.Aggregate) carry their own resolved `type`/`constraints`
  # directly — no resource-level DSL lookup by name needed (and none would
  # work for an ad-hoc/dynamically-loaded target anyway). Falls back to the
  # raw wire value on a nil type or a cast failure — never raises, so a
  # nil/error wire value passes through unchanged rather than poisoning the
  # decode.
  defp cast_typed(nil, _constraints, value), do: value

  defp cast_typed(type, constraints, value) do
    case Ash.Type.cast_input(type, value, constraints || []) do
      {:ok, casted} -> casted
      _ -> value
    end
  end
end
