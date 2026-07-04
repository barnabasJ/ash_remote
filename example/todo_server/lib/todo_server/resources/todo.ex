defmodule TodoServer.Todo do
  @moduledoc """
  A todo owned by the authenticated user. Read/update/destroy are owner-only —
  enforced on both RPC and realtime delivery — and create relates the row to the
  actor. `AshRemote.Server.Notifier` replicates changes to subscribed clients.
  """
  use Ash.Resource,
    domain: TodoServer.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [AshRemote.Server.Notifier]

  ets do
    private?(false)
  end

  policies do
    # Own it OR it's public → visible AND editable by everyone (collaborative),
    # so a public todo's changes reach — and can be made by — every user. A
    # private todo is owner-only, on both RPC and realtime delivery.
    policy action_type([:read, :update, :destroy]) do
      authorize_if(relates_to_actor_via(:user))
      authorize_if(expr(public == true))
    end

    policy action_type(:create) do
      authorize_if(actor_present())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:completed, :boolean, public?: true, default: false, allow_nil?: false)
    # Public todos are visible to (and replicated to) every user; private ones
    # only to their owner.
    attribute(:public, :boolean, public?: true, default: false, allow_nil?: false)
    attribute(:priority, TodoServer.Priority, public?: true, default: :medium)
    attribute(:due_date, :date, public?: true)
    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    # Private: ownership is a server concern (set from the actor, enforced by
    # policy). The client never sees the owner, so User stays off the wire.
    belongs_to :user, TodoServer.Accounts.User do
      allow_nil?(false)
    end

    belongs_to :list, TodoServer.TodoList do
      public?(true)
      attribute_writable?(true)
    end

    belongs_to :parent, TodoServer.Todo do
      public?(true)
      attribute_writable?(true)
    end

    has_many :subtasks, TodoServer.Todo do
      public?(true)
      destination_attribute(:parent_id)
    end
  end

  actions do
    default_accept([:title, :completed, :public, :priority, :due_date, :list_id, :parent_id])

    read :read do
      primary?(true)
    end

    create :create do
      primary?(true)
      change(relate_actor(:user))
    end

    update(:update, primary?: true)
    destroy(:destroy, primary?: true)
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
end
