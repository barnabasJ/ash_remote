defmodule AshRemote.Expressions.Remote do
  @moduledoc """
  The `remote/3` custom expression: marks a calculation whose value the remote
  backend resolves, while still letting the client filter and sort on it.

  Generated non-mirrorable client calculations are emitted as
  `expr(remote("calc_name", %{...args}, <pk>))` — the calc name, its arguments,
  and the resource's primary-key reference.

  ## Why a primary-key reference

  For a remote-backed layer the expression must route *through the data layer*
  (the value is loaded by name; the expression itself is never evaluated in
  Elixir), never fold to a compile/plan-time literal. Ash's read planner
  (`Ash.Actions.Read.Calculations.try_evaluate/5`) short-circuits any expression
  calculation it can evaluate up front — a fragment with no record dependency
  evaluates to a constant and gets frozen as a literal. Returning the record's
  **primary-key reference** avoids that: a bare ref evaluates to `:unknown` with
  no record, so Ash keeps the calc in the query and hands it to the data layer —
  exactly how a mirrored expression calc that references a real attribute behaves.
  The ref's value is never used: on `AshRemote.DataLayer` the value is fetched by
  name in the same `/rpc/run` (via `AshRemote.Encode.Fields`), and filters/sorts
  reduce to the calc name on the wire (the backend evaluates them — never
  fetch-everything-and-filter-in-memory).

  ## Layer advertising

  `:unknown` for every non-remote layer (`Ets`/`Simple`, and any other) advertises
  "the client cannot evaluate this here" — a remote calc has no client-side value.
  This is the signal `ash_multi_datalayer` reads to route a query filtering or
  sorting on such a calc to the layer that *can* resolve it (the remote L2),
  rather than trying to serve it from the cache.
  """
  use Ash.CustomExpression,
    name: :remote,
    arguments: [
      [:string, :map, :any]
    ]

  @remote_layers [AshRemote.DataLayer, AshMultiDatalayer.DataLayer]

  @impl true
  def expression(data_layer, [_name, _args, pk]) when data_layer in @remote_layers do
    {:ok, pk}
  end

  def expression(_data_layer, _args), do: :unknown
end
