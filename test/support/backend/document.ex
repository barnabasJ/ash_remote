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
    attribute(:public, :boolean, public?: true, default: false, allow_nil?: false)
  end

  actions do
    default_accept([:title, :owner_id, :public])
    defaults([:read, :create, :update, :destroy])
  end

  policies do
    # Readable by the owner OR if public — both branches reference only attributes
    # carried on the wire, so realtime delivery resolves them in-memory (including
    # a public record's destroy, whose row is gone).
    policy action_type(:read) do
      authorize_if(expr(owner_id == ^actor(:id)))
      authorize_if(expr(public == true))
    end

    # Writes are unrestricted here (the test drives them server-side).
    policy action_type([:create, :update, :destroy]) do
      authorize_if(always())
    end
  end
end
