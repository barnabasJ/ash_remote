defmodule AshRemote.Server.Fields do
  @moduledoc """
  Server-side field-selection logic for the RPC protocol.

  Part of the ported (from `ash_typescript`) server core that lives in
  `ash_remote` for now and would later be extracted into a shared protocol
  package used by both `ash_typescript` and `ash_remote`.

  Converts the wire `fields` selection into an Ash `{select, load}` pair and
  serializes result records back down to exactly the requested selection.
  """

  alias Ash.Resource.Info

  @doc "Convert a wire `fields` list into `{select, load}` for the resource."
  def to_select_and_load(resource, fields) when is_list(fields) do
    {select, load} =
      Enum.reduce(fields, {[], []}, fn field, {select, load} ->
        add_field(resource, field, select, load)
      end)

    pk = Info.primary_key(resource)
    {Enum.uniq(pk ++ Enum.reverse(select)), Enum.reverse(load)}
  end

  defp add_field(resource, name, select, load) when is_binary(name) do
    case public_name(resource, name) do
      {:ok, atom} -> add_named(resource, atom, select, load)
      :error -> {select, load}
    end
  end

  defp add_field(resource, %{} = map, select, load) do
    [{key, spec}] = Map.to_list(map)
    name = public_name!(resource, key)

    cond do
      relationship?(resource, name) ->
        dest = related(resource, name)
        {sub_select, sub_load} = to_select_and_load(dest, subfields(spec))
        rel_query = dest |> Ash.Query.select(sub_select) |> Ash.Query.load(sub_load)
        {select, [{name, rel_query} | load]}

      calculation?(resource, name) ->
        args = spec |> args() |> atomize_keys()
        {select, [{name, args} | load]}

      aggregate?(resource, name) ->
        {select, [name | load]}

      true ->
        {select, load}
    end
  end

  defp add_named(resource, name, select, load) do
    cond do
      attribute?(resource, name) -> {[name | select], load}
      aggregate?(resource, name) -> {select, [name | load]}
      calculation?(resource, name) -> {select, [name | load]}
      relationship?(resource, name) -> {select, [name | load]}
      true -> {select, load}
    end
  end

  @doc "Serialize a record (or list) down to the requested wire fields."
  def serialize(nil, _resource, _fields), do: nil

  def serialize(records, resource, fields) when is_list(records) do
    Enum.map(records, &serialize(&1, resource, fields))
  end

  def serialize(record, resource, fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      case field do
        name when is_binary(name) ->
          case public_name(resource, name) do
            {:ok, atom} -> Map.put(acc, name, value(field_value(record, resource, atom)))
            :error -> acc
          end

        %{} = map ->
          [{key, spec}] = Map.to_list(map)
          atom = public_name!(resource, key)
          val = field_value(record, resource, atom)

          if relationship?(resource, atom) do
            dest = related(resource, atom)
            Map.put(acc, key, serialize(loaded(val), dest, subfields(spec)))
          else
            Map.put(acc, key, value(val))
          end
      end
    end)
  end

  defp loaded(%Ash.NotLoaded{}), do: nil
  defp loaded(%Ash.ForbiddenField{}), do: nil
  defp loaded(other), do: other
  defp value(%Ash.NotLoaded{}), do: nil
  defp value(%Ash.ForbiddenField{}), do: nil
  defp value(other), do: other

  defp field_value(record, resource, atom) do
    cond do
      aggregate?(resource, atom) -> loaded_value(record, :aggregates, atom)
      calculation?(resource, atom) -> loaded_value(record, :calculations, atom)
      true -> Map.get(record, atom)
    end
  end

  defp loaded_value(record, load_key, atom) do
    values = Map.get(record, load_key, %{}) || %{}

    if is_map(values) and Map.has_key?(values, atom) do
      Map.get(values, atom)
    else
      Map.get(record, atom)
    end
  end

  defp subfields(spec) when is_list(spec), do: spec
  defp subfields(%{"fields" => fields}), do: fields
  defp subfields(_), do: []

  defp args(%{"args" => args}) when is_map(args), do: args
  defp args(_), do: %{}

  defp atomize_keys(map),
    do: Map.new(map, fn {k, v} -> {String.to_existing_atom(to_string(k)), v} end)

  defp attribute?(resource, name), do: not is_nil(Info.public_attribute(resource, name))
  defp aggregate?(resource, name), do: not is_nil(Info.public_aggregate(resource, name))
  defp calculation?(resource, name), do: not is_nil(Info.public_calculation(resource, name))
  defp relationship?(resource, name), do: not is_nil(Info.public_relationship(resource, name))
  defp related(resource, name), do: Info.public_relationship(resource, name).destination

  defp public_name(resource, name) do
    atom = String.to_existing_atom(name)

    if attribute?(resource, atom) or aggregate?(resource, atom) or calculation?(resource, atom) or
         relationship?(resource, atom) do
      {:ok, atom}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  defp public_name!(resource, name) do
    case public_name(resource, name) do
      {:ok, atom} ->
        atom

      :error ->
        raise ArgumentError,
              "unknown or non-public field #{inspect(name)} for #{inspect(resource)}"
    end
  end
end
