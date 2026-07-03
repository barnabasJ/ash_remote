defmodule TodoServer.TodoList do
  @moduledoc false
  use Ash.Resource, domain: TodoServer.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? false
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true, allow_nil?: false
  end

  relationships do
    belongs_to :user, TodoServer.User, public?: true, attribute_writable?: true
    has_many :todos, TodoServer.Todo, public?: true, destination_attribute: :list_id
  end

  aggregates do
    count :todo_count, :todos do
      public? true
    end

    count :completed_count, :todos do
      public? true
      filter expr(completed)
    end
  end

  actions do
    default_accept [:name, :user_id]

    read :read do
      primary? true
    end

    create :create, primary?: true
    update :update, primary?: true
    destroy :destroy, primary?: true
  end
end
