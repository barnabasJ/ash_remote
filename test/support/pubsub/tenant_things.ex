defmodule AshRemote.PubSubFixture.AttrTenantThing do
  @moduledoc """
  Attribute-multitenant resource with `AshRemote.Server.Notifier` attached —
  M8's fixture: proves a changeset-less notification derives the tenant
  from the record's own multitenancy attribute rather than publishing to
  the unjoinable untenanted topic.
  """
  use Ash.Resource,
    domain: AshRemote.PubSubFixture.PubDomain,
    data_layer: Ash.DataLayer.Ets,
    notifiers: [AshRemote.Server.Notifier]

  ets do
    private?(false)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:org_id)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org_id, :string, public?: true, allow_nil?: false)
    attribute(:title, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshRemote.PubSubFixture.CtxTenantThing do
  @moduledoc """
  Context-multitenant resource with `AshRemote.Server.Notifier` attached —
  M8's fixture: proves a changeset-less notification, which has no way to
  recover the tenant (it lives only in changeset/context, never on the
  record), is never published to the unjoinable untenanted topic — and
  that the fallback emits a concrete, observable signal instead of
  silently dropping it.
  """
  use Ash.Resource,
    domain: AshRemote.PubSubFixture.PubDomain,
    data_layer: Ash.DataLayer.Ets,
    notifiers: [AshRemote.Server.Notifier]

  ets do
    private?(false)
  end

  multitenancy do
    strategy(:context)
    global?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
