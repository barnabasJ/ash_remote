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
    # Writable primary key: an offline-first LocalOutbox client generates the id
    # locally and replicates it, so the same row shares one id on both sides.
    # Optional on create (a normal online client omits it → default generates).
    attribute :id, :uuid do
      primary_key?(true)
      allow_nil?(false)
      writable?(true)
      default(&Ash.UUID.generate/0)
      public?(true)
    end

    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:completed, :boolean, public?: true, default: false, allow_nil?: false)
    # Public todos are visible to (and replicated to) every user; private ones
    # only to their owner.
    attribute(:public, :boolean, public?: true, default: false, allow_nil?: false)
    attribute(:priority, TodoServer.Priority, public?: true, default: :medium)
    attribute(:due_date, :date, public?: true)
    create_timestamp(:inserted_at, public?: true)
    # Still auto-stamped for display, but NO LONGER the conflict field — a
    # server-assigned timestamp is unpredictable to a client, so it can never
    # pre-fill a matching stale-check base image (a fresh local row has no
    # server timestamp yet) and every offline update/destroy would false-park.
    update_timestamp(:updated_at, public?: true)

    # The conflict field a LocalOutbox client stale-checks against. Deliberately
    # a **plain, client-authored** integer (accepted below, never auto-managed):
    # the client owns and increments it, so it can predict its own version chain
    # (an offline create→update→destroy is v1→v2→v3, each flush's base matches)
    # while a *peer's* write still advances the server's copy and trips a real
    # conflict. Monotonic and skew-free, unlike a wall-clock timestamp.
    attribute(:version, :integer, public?: true, default: 1, allow_nil?: false)
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
    default_accept([
      :id,
      :title,
      :completed,
      :public,
      :priority,
      :due_date,
      :list_id,
      :parent_id,
      # Stored verbatim from the client — the server must NOT author this, or the
      # client's stale-check base image could never match (see the attribute).
      :version
    ])

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
