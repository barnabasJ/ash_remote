defmodule AshRemote.CaptureArguments do
  @moduledoc """
  Read preparation (added to generated read actions) that captures the
  query's caller-supplied action-argument *values* into context, where
  `AshRemote.DataLayer` can find them for the wire request's `input`.

  No standard `Ash.DataLayer` callback receives the argument values a
  specific call supplied. `context.action` (populated by Ash's generic
  pipeline, already relied on elsewhere in the data layer — see `get?/1`)
  carries only the action's static *definition*: argument names/types, never
  a particular call's actual values. Those live on `Ash.Query.arguments`.
  `transform_query/1` looked like the obvious hook (it's the one
  `Ash.DataLayer` callback given the full `Ash.Query.t()`) but fires at
  `Ash.Query.new/2` — before `Ash.Query.for_read/4` casts any arguments at
  all, so `query.arguments` is always empty there. A `prepare`, run as part
  of actually applying the read action, is the first point with both the
  full query *and* cast argument values.
  """
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    if query.arguments == %{} do
      query
    else
      Ash.Query.set_context(query, %{ash_remote_arguments: query.arguments})
    end
  end
end
