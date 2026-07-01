defmodule AshRemote.Backend.Rpc.Fields do
  @moduledoc """
  Ported (template) field-selection logic for the reference backend's RPC core.

  Converts the wire `fields` selection (a nested list of names / single-key maps)
  into an Ash `{select, load}` pair, and serializes result records back down to
  exactly the requested selection.

  Wire shapes:

    * `"title"`                                    — attribute / scalar calc / aggregate
    * `%{"user" => ["id", "name"]}`                — relationship with nested fields
    * `%{"title_with_prefix" => %{"args" => %{"prefix" => "x"}}}` — calc with args
    * `%{"comment_count" => []}`                   — aggregate (empty selection)

  Written dependency-free (resource passed in) so it can be extracted into a
  shared protocol package later.
  """

  alias Ash.Resource.Info

  @doc "Convert a wire fields list into `{select, load}` for the given resource."
  def to_select_and_load(resource, fields) when is_list(fields) do
    {select, load} =
      Enum.reduce(fields, {[], []}, fn field, {select, load} ->
        add_field(resource, field, select, load)
      end)

    # Always select the primary key so records can be identified/decoded.
    pk = Info.primary_key(resource)
    {Enum.uniq(pk ++ Enum.reverse(select)), Enum.reverse(load)}
  end

  defp add_field(resource, name, select, load) when is_binary(name) do
    add_named(resource, String.to_existing_atom(name), select, load)
  end

  defp add_field(resource, %{} = map, select, load) do
    [{key, spec}] = Map.to_list(map)
    name = String.to_existing_atom(key)

    cond do
      relationship?(resource, name) ->
        dest = related(resource, name)
        {sub_select, sub_load} = to_select_and_load(dest, subfields(spec))
        rel_query = dest |> Ash.Query.select(sub_select) |> Ash.Query.load(sub_load)
        {select, [{name, rel_query} | load]}

      calculation?(resource, name) ->
        args = spec |> args(spec) |> atomize_keys()
        {select, [{name, args} | load]}

      true ->
        # aggregate with an empty selection, or unknown → treat as a load
        {select, [name | load]}
    end
  end

  defp add_named(resource, name, select, load) do
    cond do
      attribute?(resource, name) -> {[name | select], load}
      aggregate?(resource, name) -> {select, [name | load]}
      calculation?(resource, name) -> {select, [name | load]}
      relationship?(resource, name) -> {select, [name | load]}
      true -> {[name | select], load}
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
          atom = String.to_existing_atom(name)
          Map.put(acc, name, value(Map.get(record, atom)))

        %{} = map ->
          [{key, spec}] = Map.to_list(map)
          atom = String.to_existing_atom(key)
          val = Map.get(record, atom)

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
  defp loaded(other), do: other

  defp value(%Ash.NotLoaded{}), do: nil
  defp value(other), do: other

  defp subfields(spec) when is_list(spec), do: spec
  defp subfields(%{"fields" => fields}), do: fields
  defp subfields(_), do: []

  defp args(_spec, %{"args" => args}) when is_map(args), do: args
  defp args(_spec, _), do: %{}

  defp atomize_keys(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(to_string(k)), v} end)
  end

  defp attribute?(resource, name), do: not is_nil(Info.attribute(resource, name))
  defp aggregate?(resource, name), do: not is_nil(Info.aggregate(resource, name))
  defp calculation?(resource, name), do: not is_nil(Info.calculation(resource, name))
  defp relationship?(resource, name), do: not is_nil(Info.relationship(resource, name))
  defp related(resource, name), do: Info.relationship(resource, name).destination
end
