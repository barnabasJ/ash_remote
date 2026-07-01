defmodule TodoClient.Remote.Todo do
  use Ash.Resource,
    domain: TodoClient.Remote.Domain,
    data_layer: AshRemote.DataLayer,
    extensions: [AshRemote.Resource]

  remote do
    source("TodoServer.Todo")
    schema_version("1.0.0")
    managed_attributes([:completed, :due_date, :id, :inserted_at, :priority, :title])
    managed_relationships([:user])
    managed_calculations([:overdue?])
    managed_actions([:create, :destroy, :read, :update])
  end

  attributes do
    attribute(:completed, :boolean, public?: true)
    attribute(:due_date, :date, public?: true)
    uuid_primary_key(:id)
    attribute(:inserted_at, :utc_datetime_usec, public?: true)
    attribute(:priority, TodoClient.Remote.Priority, public?: true)
    attribute(:title, :string, public?: true, allow_nil?: false)
  end

  relationships do
    belongs_to(:user, TodoClient.Remote.User, public?: true, attribute_writable?: true)
  end

  calculations do
    calculate :overdue?, :boolean, expr(not is_nil(id)) do
      public?(true)
    end
  end

  actions do
    create :create do
      primary?(true)
      accept([:title, :completed, :priority, :due_date, :user_id])
    end

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
    end

    read :read do
      primary?(true)
    end

    update :update do
      primary?(true)
      require_atomic?(false)
      accept([:title, :completed, :priority, :due_date, :user_id])
    end
  end
end
