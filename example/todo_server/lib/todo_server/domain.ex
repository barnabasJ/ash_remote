defmodule TodoServer.Domain do
  @moduledoc "The todo backend domain — its RPC-exposed and realtime-published surface."
  use Ash.Domain, extensions: [AshRemote.Rpc]

  resources do
    resource(TodoServer.TodoList)
    resource(TodoServer.Todo)
  end

  rpc do
    # Realtime notifications are broadcast through the Phoenix endpoint.
    pub_sub(TodoServer.Endpoint)

    resource TodoServer.TodoList do
      expose(:read)
      expose(:create)
      expose(:update)
      expose(:destroy)
    end

    resource TodoServer.Todo do
      expose(:read)
      expose(:create)
      expose(:update)
      expose(:destroy)
    end
  end
end
