defmodule AshRemote.Backend.Todo do
  @moduledoc false
  use Ash.Resource,
    domain: AshRemote.Backend.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? false
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string, public?: true, allow_nil?: false
    attribute :completed, :boolean, public?: true, default: false, allow_nil?: false
    attribute :status, AshRemote.Backend.Todo.Status, public?: true, default: :pending
    attribute :priority_score, AshRemote.Backend.PriorityScore, public?: true
    attribute :due_date, :date, public?: true
  end

  relationships do
    belongs_to :user, AshRemote.Backend.User do
      public? true
      attribute_writable? true
    end

    has_many :comments, AshRemote.Backend.Comment, public?: true
  end

  aggregates do
    count :comment_count, :comments do
      public? true
    end
  end

  calculations do
    # Calculation WITHOUT an argument (expression).
    calculate :is_overdue,
              :boolean,
              expr(not is_nil(due_date) and due_date < today() and not completed) do
      public? true
    end

    # Calculation WITH an argument.
    calculate :title_with_prefix, :string, AshRemote.Backend.Todo.TitleWithPrefix do
      public? true

      argument :prefix, :string do
        allow_nil? false
        default ""
      end
    end
  end

  actions do
    default_accept [:title, :completed, :status, :priority_score, :due_date, :user_id]

    read :read do
      primary? true

      pagination offset?: true,
                 keyset?: true,
                 countable: true,
                 default_limit: 20,
                 required?: false
    end

    read :get_by_id do
      get_by :id
    end

    create :create do
      primary? true
    end

    update :update do
      primary? true
      require_atomic? false
    end

    update :complete do
      accept []
      require_atomic? false
      change set_attribute(:completed, true)
    end

    destroy :destroy do
      primary? true
    end
  end
end
