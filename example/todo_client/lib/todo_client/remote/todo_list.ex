defmodule TodoClient.Remote.TodoList do
  # Hand-edited after `mix ash_remote.gen` — re-apply after any regen (see the
  # client README). Same three edits as `TodoClient.Remote.Todo`, plus
  # `fold_aggregate_overrides([:completed_count])`: `todo_count` is folded
  # from the cached todos (0 RPC when covered), while `completed_count` is
  # opted out — forwarded to the server by name (1 RPC) — the two aggregate
  # strategies side by side in the demo UI.
  use Ash.Resource,
    domain: TodoClient.Remote.Domain,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [AshRemote.Resource],
    notifiers: [AshRemote.MultiDatalayer.ChangeNotifier, TodoClient.RealtimeBridge]

  multi_data_layer do
    layer(:cache, Ash.DataLayer.Ets)
    layer(:remote, AshRemote.DataLayer)

    read_order([:cache, :remote])
    write_order([:remote, :cache])

    fold_aggregate_overrides([:completed_count])
  end

  remote do
    source("TodoServer.TodoList")
    schema_version("1.0.0")
    realtime?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:inserted_at, :utc_datetime_usec, public?: true)
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:public, :boolean, public?: true)
  end

  relationships do
    has_many(:todos, TodoClient.Remote.Todo,
      public?: true,
      source_attribute: :id,
      destination_attribute: :list_id
    )
  end

  aggregates do
    count :completed_count, :todos do
      public?(true)
      filter(expr(completed))
    end

    count :todo_count, :todos do
      public?(true)
    end
  end

  actions do
    create :create do
      primary?(true)
      accept([:name, :public])
    end

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
    end

    read :read do
      primary?(true)
      prepare(AshRemote.PrefetchCalculations)
    end

    update :update do
      primary?(true)
      require_atomic?(false)
      accept([:name, :public])
    end
  end
end
