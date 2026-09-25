defmodule AshRemote.Backend.User do
  @moduledoc false
  use Ash.Resource,
    domain: AshRemote.Backend.Domain,
    data_layer: Ash.DataLayer.Ets,
    notifiers: [AshRemote.Server.Notifier]

  ets do
    private? false
  end

  actions do
    defaults [:read, create: :*]

    read :get_by_id do
      get_by :id
    end

    # Explicit, not `defaults([:destroy, update: :*])`: Ets can't run these
    # atomically for this resource (its `unique_email` identity uses
    # `pre_check_with:`, which doesn't support atomic mode), and
    # `default_actions_require_atomic?: true` would otherwise require it.
    update :update do
      primary? true
      accept :*
      require_atomic? false
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, public?: true, allow_nil?: false
    attribute :email, :string, public?: true
    # A `writable?: false`, non-PK attribute — mirrors a real resource's
    # auto-managed `inserted_at`/`updated_at`, for the H2 replicated-write
    # accepted_keys/1 regression test below.
    update_timestamp :updated_at, public?: true
  end

  relationships do
    has_many :todos, AshRemote.Backend.Todo, public?: true
  end

  identities do
    identity :unique_email, [:email], pre_check_with: AshRemote.Backend.Domain
  end
end
