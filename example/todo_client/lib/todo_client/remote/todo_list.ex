defmodule TodoClient.Remote.TodoList do
  use Ash.Resource,
    domain: TodoClient.Remote.Domain,
    data_layer: AshRemote.DataLayer,
    extensions: [AshRemote.Resource],
    notifiers: [TodoClient.RealtimeBridge]

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
