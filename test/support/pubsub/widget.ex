defmodule AshRemote.PubSubFixture.Widget do
  @moduledoc """
  Minimal ETS resource used to exercise `Rpc.Info.publications/1` precedence
  (expose/publish/no_publish). No notifier, no realtime transport — the fixture
  domain sets no `pub_sub`, so the publish verifier stays quiet.
  """
  use Ash.Resource,
    domain: AshRemote.PubSubFixture.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(false)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read, :create, :update, :destroy])

    update :internal_touch do
      accept([])
    end

    update :bar_touch do
      accept([])
    end
  end
end
