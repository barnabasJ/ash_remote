defmodule TodoServer.Todo do
  @moduledoc false
  use Ash.Resource, domain: TodoServer.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? false
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true, allow_nil?: false
    attribute :completed, :boolean, public?: true, default: false, allow_nil?: false
    attribute :priority, TodoServer.Priority, public?: true, default: :medium
    attribute :due_date, :date, public?: true
    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :user, TodoServer.User, public?: true, attribute_writable?: true
  end

  calculations do
    calculate :overdue?,
              :boolean,
              expr(not is_nil(due_date) and due_date < today() and not completed) do
      public? true
    end
  end

  actions do
    default_accept [:title, :completed, :priority, :due_date, :user_id]

    read :read do
      primary? true
    end

    create :create, primary?: true
    update :update, primary?: true

    update :complete do
      accept []
      require_atomic? false
      change set_attribute(:completed, true)
    end

    update :reopen do
      accept []
      require_atomic? false
      change set_attribute(:completed, false)
    end

    destroy :destroy, primary?: true
  end
end
