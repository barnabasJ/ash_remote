defmodule TodoClient.Remote.Todo do
  # Hand-edited after `mix ash_remote.gen` — re-apply after any regen (see the
  # client README): swapped `data_layer:` for `AshMultiDatalayer.DataLayer`
  # (+ the `multi_data_layer` block below) to front the remote data layer with
  # an ETS cache, and added AshRemote.MultiDatalayer.ChangeNotifier (FIRST in the
  # list — see its moduledoc for why, and why this must be a literal list
  # rather than built via a helper call) so a realtime notification
  # invalidates this client's cache before the UI refetches.
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
  end

  remote do
    source("TodoServer.Todo")
    schema_version("1.0.0")
    realtime?(true)
  end

  attributes do
    attribute(:completed, :boolean, public?: true)
    attribute(:due_date, :date, public?: true)
    uuid_primary_key(:id)
    attribute(:inserted_at, :utc_datetime_usec, public?: true)
    attribute(:priority, TodoClient.Remote.Priority, public?: true)
    attribute(:public, :boolean, public?: true)
    attribute(:title, :string, public?: true, allow_nil?: false)
  end

  relationships do
    belongs_to(:list, TodoClient.Remote.TodoList,
      public?: true,
      attribute_writable?: true,
      source_attribute: :list_id,
      destination_attribute: :id
    )

    belongs_to(:parent, TodoClient.Remote.Todo,
      public?: true,
      attribute_writable?: true,
      source_attribute: :parent_id,
      destination_attribute: :id
    )

    has_many(:subtasks, TodoClient.Remote.Todo,
      public?: true,
      source_attribute: :id,
      destination_attribute: :parent_id
    )
  end

  validations do
    validate(string_length(:title, min: 3))
  end

  calculations do
    calculate :overdue?,
              :boolean,
              expr(not is_nil(due_date) and due_date < today() and not completed) do
      public?(true)
    end
  end

  actions do
    create :create do
      primary?(true)
      accept([:title, :completed, :public, :priority, :due_date, :list_id, :parent_id])
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
      accept([:title, :completed, :public, :priority, :due_date, :list_id, :parent_id])
    end
  end
end
