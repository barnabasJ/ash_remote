defmodule AshRemote.Backend.Domain do
  @moduledoc "Reference backend domain — the RPC-exposed surface for tests."
  use Ash.Domain, extensions: [AshRemote.Rpc]

  resources do
    resource(AshRemote.Backend.User)
    resource(AshRemote.Backend.Todo)
    resource(AshRemote.Backend.Comment)
  end

  rpc do
    pub_sub(AshRemote.Backend.Endpoint)

    resource AshRemote.Backend.Todo do
      expose(:read)
      expose(:create)
      expose(:update)
      expose(:destroy)
    end

    resource AshRemote.Backend.User do
      expose(:read)
      expose(:create)
    end

    resource AshRemote.Backend.Comment do
      expose(:read)
      expose(:create)
      # gate: create is exposed over RPC but opted OUT of realtime publication
      no_publish(:create)
    end
  end
end
