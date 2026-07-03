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
    belongs_to :list, TodoServer.TodoList, public?: true, attribute_writable?: true
    belongs_to :parent, TodoServer.Todo, public?: true, attribute_writable?: true
    has_many :subtasks, TodoServer.Todo, public?: true, destination_attribute: :parent_id
  end

  validations do
    # Mirrored onto the generated client resource: forms validate this
    # without a round trip; the server still enforces it on every write.
    validate string_length(:title, min: 3)
  end

  calculations do
    calculate :overdue?,
              :boolean,
              expr(not is_nil(due_date) and due_date < today() and not completed) do
      public? true
    end
  end

  actions do
    default_accept [:title, :completed, :priority, :due_date, :list_id, :parent_id]

    read :read do
      primary? true
    end

    create :create, primary?: true
    update :update, primary?: true
    destroy :destroy, primary?: true
  end
end
