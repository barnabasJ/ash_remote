defmodule AshRemote.Encode.Fields do
  @moduledoc """
  Builds the wire `fields` selection (and a decode plan) from a query's
  attribute select, calculations, and aggregates.

  Relationship loads are NOT folded here — Ash loads relationships via its own
  (batched) follow-up reads against the related resource's data layer, which is
  also `AshRemote.DataLayer`.
  """

  @doc """
  Returns `{fields, plan}` where `fields` is the wire selection and `plan` is a
  list of `{wire_key, target}` describing how to place each decoded value:

    * `{:attribute, name}`
    * `{:calculation, calc_struct}`
    * `{:aggregate, agg_struct}`
  """
  def build(%AshRemote.Query{} = query) do
    resource = query.resource
    pk = Ash.Resource.Info.primary_key(resource)
    attrs = Enum.uniq(pk ++ query.select)

    attr_fields = Enum.map(attrs, &to_string/1)
    attr_plan = Enum.map(attrs, &{to_string(&1), {:attribute, &1}})

    {calc_fields, calc_plan} =
      query.calculations
      |> Enum.map(&calc_entry/1)
      |> Enum.unzip()

    {agg_fields, agg_plan} =
      query.aggregates
      |> Enum.map(&agg_entry/1)
      |> Enum.unzip()

    {attr_fields ++ calc_fields ++ agg_fields, attr_plan ++ calc_plan ++ agg_plan}
  end

  defp calc_entry(%Ash.Query.Calculation{} = calc) do
    name = calc.calc_name || calc.name
    key = to_string(name)
    args = calc |> arguments() |> stringify_keys()

    field = if args == %{}, do: key, else: %{key => %{"args" => args}}
    {field, {key, {:calculation, calc}}}
  end

  defp agg_entry(%Ash.Query.Aggregate{} = agg) do
    name = agg.agg_name || agg.name
    key = to_string(name)
    {%{key => []}, {key, {:aggregate, agg}}}
  end

  defp arguments(%Ash.Query.Calculation{context: %{arguments: args}}) when is_map(args), do: args
  defp arguments(_), do: %{}

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
