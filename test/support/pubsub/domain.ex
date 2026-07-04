defmodule AshRemote.PubSubFixture.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshRemote.Rpc], validate_config_inclusion?: false

  resources do
    resource(AshRemote.PubSubFixture.Widget)
  end

  rpc do
    resource AshRemote.PubSubFixture.Widget do
      expose(:create)
      expose(:update)

      # opt an unexposed action IN
      publish(:internal_touch)

      # no_publish beats an exposed action
      no_publish(:create)

      # no_publish beats publish for the same action
      publish(:bar_touch)
      no_publish(:bar_touch)
    end
  end
end
