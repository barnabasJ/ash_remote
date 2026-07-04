defmodule AshRemote.PubSubFixture.PubDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshRemote.Rpc], validate_config_inclusion?: false

  resources do
    resource(AshRemote.PubSubFixture.Post)
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
  end
end
