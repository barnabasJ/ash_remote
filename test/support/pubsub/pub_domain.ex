defmodule AshRemote.PubSubFixture.PubDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshRemote.Rpc], validate_config_inclusion?: false

  resources do
    resource(AshRemote.PubSubFixture.Post)
    resource(AshRemote.PubSubFixture.AttrTenantThing)
    resource(AshRemote.PubSubFixture.CtxTenantThing)
  end

  rpc do
    pub_sub(AshRemote.PubSubFixture.TestPubSub)

    resource AshRemote.PubSubFixture.Post do
      expose(:create)
      expose(:update)
      expose(:destroy)
      # gate: destroy is exposed but opted out of realtime
      no_publish(:destroy)
    end

    resource AshRemote.PubSubFixture.AttrTenantThing do
      expose(:create)
      expose(:update)
    end

    resource AshRemote.PubSubFixture.CtxTenantThing do
      expose(:create)
      expose(:update)
    end
  end
end
