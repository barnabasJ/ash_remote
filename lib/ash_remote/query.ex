defmodule AshRemote.Query do
  @moduledoc """
  Accumulator struct built up by `AshRemote.DataLayer` query callbacks, then
  encoded into an `/rpc/run` body by `run_query`.
  """

  @type t :: %__MODULE__{
          resource: module(),
          domain: module(),
          filter: term() | nil,
          sort: list(),
          limit: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          select: [atom()],
          calculations: [Ash.Query.Calculation.t()],
          aggregates: [Ash.Query.Aggregate.t()],
          tenant: term(),
          context: map()
        }

  defstruct resource: nil,
            domain: nil,
            filter: nil,
            sort: [],
            limit: nil,
            offset: nil,
            select: [],
            calculations: [],
            aggregates: [],
            tenant: nil,
            context: %{}
end
