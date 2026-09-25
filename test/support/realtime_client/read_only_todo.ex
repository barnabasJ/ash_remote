defmodule AshRemote.RealtimeClient.ReadOnlyTodo do
  @moduledoc """
  A realtime client mirror with NO `:update`/`:create`/`:destroy` action at
  all — the shape of a resource whose backend counterpart has admin-only
  mutations a worker-facing client never mirrors (e.g. `Arcc.Scheduling
  .Session`'s `approve`/`decline`, replicated only to invalidate a worker's
  local cache). `AshRemote.Realtime.Inbound.resolve_action/3` must still
  resolve *some* action (a synthetic one) for such a resource, so its
  notifiers still fire on a replicated update — see the regression this
  guards in `realtime_no_local_action_test.exs`.
  """
  use Ash.Resource,
    domain: AshRemote.RealtimeClient.Domain,
    data_layer: AshRemote.DataLayer,
    notifiers: [AshRemote.RealtimeClient.CaptureNotifier]

  remote do
    source "AshRemote.Backend.Todo"
    realtime? true
  end

  actions do
    default_accept [:title, :completed, :status, :priority_score, :due_date]
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true, allow_nil?: false
    attribute :completed, :boolean, public?: true, default: false, allow_nil?: false
    attribute :status, AshRemote.Backend.Todo.Status, public?: true
    attribute :priority_score, AshRemote.Backend.PriorityScore, public?: true
    attribute :due_date, :date, public?: true
  end
end
