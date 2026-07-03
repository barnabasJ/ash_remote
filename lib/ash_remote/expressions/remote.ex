defmodule AshRemote.Expressions.Remote do
  @moduledoc """
  The `remote/1,2` custom expression: marks a calculation whose value the remote
  backend resolves, while still letting the client filter and sort on it.

  Generated non-mirrorable client calculations are emitted as
  `expr(remote("calc_name"))` (or `expr(remote("calc_name", %{arg: v}))`). The
  returned expression is a real (non-constant) `fragment` so Ash does not
  constant-fold it and actually routes the calculation through the data layer:

    * on `AshRemote.DataLayer` the value is fetched by name in the same
      `/rpc/run` (via `AshRemote.Encode.Fields`), and filters/sorts reduce to the
      calc name on the wire (the backend evaluates them — never
      fetch-everything-and-filter-in-memory);
    * on an elixir-backed layer (`Ets`/`Simple`, e.g. rows served by a cache
      layer under ash_multi_datalayer) the fragment resolves the value in Elixir.

  `:unknown` for other layers advertises "the client cannot evaluate this here",
  which is the signal ash_multi_datalayer reads to route to the layer that can.
  """
  use Ash.CustomExpression,
    name: :remote,
    arguments: [
      [:string],
      [:string, :map]
    ]

  @remote_layers [AshRemote.DataLayer, AshMultiDatalayer.DataLayer]
  @elixir_layers [Ash.DataLayer.Ets, Ash.DataLayer.Simple]

  @impl true
  def expression(data_layer, args) when data_layer in @remote_layers do
    {:ok, fragment_for(args)}
  end

  def expression(data_layer, args) when data_layer in @elixir_layers do
    {:ok, fragment_for(args)}
  end

  def expression(_data_layer, _args), do: :unknown

  defp fragment_for([name | _rest]) do
    expr(fragment(&__MODULE__.resolve/1, ^name))
  end

  @doc false
  # Placeholder resolver. On AshRemote the value is loaded by name via `Fields`
  # and this is never called; the real elixir-side bundled fetch is wired next.
  def resolve(name), do: name
end
