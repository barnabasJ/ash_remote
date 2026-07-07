defmodule AshRemote.Backend.Domain do
  @moduledoc "Reference backend domain — the RPC-exposed surface for tests."
  use Ash.Domain, extensions: [AshRemote.Rpc]

  resources do
    resource(AshRemote.Backend.User)
    resource(AshRemote.Backend.Todo)
    resource(AshRemote.Backend.Comment)
    resource(AshRemote.Backend.Note)
    resource(AshRemote.Backend.RaceItem)
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
      # H2: non-PK upsert identity tests need the update RPC path (an
      # upsert that resolves to "row exists" dispatches to update/2).
      expose(:update)
    end

    resource AshRemote.Backend.Comment do
      expose(:read)
      expose(:create)
      # gate: create is exposed over RPC but opted OUT of realtime publication
      no_publish(:create)
    end

    resource AshRemote.Backend.Note do
      expose(:read)
      expose(:create)
      expose(:update)
      expose(:destroy)
    end

    resource AshRemote.Backend.RaceItem do
      expose(:read)
      expose(:create)
      expose(:update)
      expose(:destroy)
    end
  end
end
