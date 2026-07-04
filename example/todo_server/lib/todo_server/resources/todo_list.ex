defmodule TodoServer.TodoList do
  @moduledoc """
  A named list of todos, owned by the authenticated user. Like `TodoServer.Todo`
  it is owner-scoped and realtime-published, so a client sees only its own lists
  and their live changes.
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
    # Own it OR it's public → visible + editable by everyone (collaborative).
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
    attribute(:name, :string, public?: true, allow_nil?: false)
    # Public lists are visible to (and replicated to) every user.
    attribute(:public, :boolean, public?: true, default: false, allow_nil?: false)
    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    # Private: ownership is enforced server-side; the client never sees the owner.
    belongs_to :user, TodoServer.Accounts.User do
      allow_nil?(false)
    end

    has_many(:todos, TodoServer.Todo, public?: true, destination_attribute: :list_id)
  end

  actions do
    default_accept([:name, :public])

    read(:read, primary?: true)

    create :create do
      primary?(true)
      change(relate_actor(:user))
    end

    update(:update, primary?: true)
    destroy(:destroy, primary?: true)
  end

  aggregates do
    count(:todo_count, :todos, public?: true)
  end
end
