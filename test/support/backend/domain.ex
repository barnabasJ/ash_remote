defmodule AshRemote.Backend.Domain do
  @moduledoc "Reference backend domain — the RPC-exposed surface for tests."
  use Ash.Domain, extensions: [AshRemote.Rpc]

  resources do
    resource(AshRemote.Backend.User)
    resource(AshRemote.Backend.Todo)
    resource(AshRemote.Backend.Comment)
    resource(AshRemote.Backend.Note)
    resource(AshRemote.Backend.RaceItem)
    resource(AshRemote.Backend.Singleton)
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

    # M11: read_action_name/2 always targets the PRIMARY read action, so a
    # non-primary get_by-style action (e.g. User's get_by_id) never
    # actually reaches the server as get?: true over RPC — only a
    # resource whose PRIMARY read is itself get?: true exercises the
    # server's single-object/explicit-null response shapes.
    resource AshRemote.Backend.Singleton do
      expose(:read)
      expose(:create)
      expose(:destroy)
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
