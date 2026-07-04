defmodule AshRemote.Backend.Document do
  @moduledoc """
  A policy-protected backend resource: a document is readable only by its owner.
  Used to exercise the channel's per-record subscription authorization.
  """
  use Ash.Resource,
    domain: AshRemote.Backend.SecureDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [AshRemote.Server.Notifier]

  ets do
    private?(false)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:owner_id, :uuid, public?: true)
  end

  actions do
    default_accept([:title, :owner_id])
    defaults([:read, :create, :update, :destroy])
  end

  policies do
    # Only the owner may read a document — enforced on RPC reads AND on realtime
    # subscription delivery.
    policy action_type(:read) do
      authorize_if(expr(owner_id == ^actor(:id)))
    end

    # Writes are unrestricted here (the test drives them server-side).
    policy action_type([:create, :update, :destroy]) do
      authorize_if(always())
    end
  end
end
