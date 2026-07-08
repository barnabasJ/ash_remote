defmodule AshRemote.Backend.WhenRequestedThing do
  @moduledoc """
  L8 fixture: a resource whose domain is configured `authorize
  :when_requested` and whose policies deny by default (no actor ->
  forbidden). Used to prove `AshRemote.Server`'s dispatch/fetch/validate
  paths pass `authorize?: true` explicitly — under `:when_requested`, Ash
  only enforces policies when a caller opts in per-call, so an RPC dispatch
  that omits it silently skips authorization instead of denying.
  """
  use Ash.Resource,
    domain: AshRemote.Backend.WhenRequestedDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  ets do
    private?(false)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
  end

  actions do
    default_accept([:name])
    defaults([:read, :create, :update, :destroy])
  end

  policies do
    # Read: any present actor may read (deny-by-default still applies —
    # nil/absent actor is forbidden, exercising the read-path denial).
    policy action_type(:read) do
      authorize_if(actor_present())
    end

    # Create/update/destroy: only role: :admin may mutate. A non-admin
    # actor can therefore successfully FETCH a row (read policy above)
    # but must still be denied at the terminal mutation call — proving
    # Ash.update!/1 / Ash.destroy!/1 / Ash.create!/1 themselves run with
    # authorize?: true, not just that the fetch-helper's read succeeded.
    policy action_type([:create, :update, :destroy]) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end
  end
end

defmodule AshRemote.Backend.WhenRequestedDomain do
  @moduledoc "L8 fixture domain: `authorize :when_requested`, exposing WhenRequestedThing over RPC."
  use Ash.Domain, extensions: [AshRemote.Rpc], validate_config_inclusion?: false

  authorization do
    authorize(:when_requested)
  end

  resources do
    resource(AshRemote.Backend.WhenRequestedThing)
  end

  rpc do
    resource AshRemote.Backend.WhenRequestedThing do
      expose(:read)
      expose(:create)
      expose(:update)
      expose(:destroy)
    end
  end
end
