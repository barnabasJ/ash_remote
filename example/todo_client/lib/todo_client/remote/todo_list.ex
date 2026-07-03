defmodule TodoClient.Remote.TodoList do
  use Ash.Resource,
    domain: TodoClient.Remote.Domain,
    data_layer: AshRemote.DataLayer,
    extensions: [AshRemote.Resource]

  remote do
    source("TodoServer.TodoList")
    schema_version("1.0.0")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
  end

  relationships do
    has_many(:todos, TodoClient.Remote.Todo,
      public?: true,
      source_attribute: :id,
      destination_attribute: :list_id
    )

    belongs_to(:user, TodoClient.Remote.User,
      public?: true,
      attribute_writable?: true,
      source_attribute: :user_id,
      destination_attribute: :id
    )
  end

  calculations do
    calculate :completed_count, :integer, expr(not is_nil(id)) do
      public?(true)
    end

    calculate :todo_count, :integer, expr(not is_nil(id)) do
      public?(true)
    end
  end

  actions do
    create :create do
      primary?(true)
      accept([:name, :user_id])
    end

    read :read do
      primary?(true)
    end
  end
end
