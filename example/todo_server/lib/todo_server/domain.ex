defmodule TodoServer.Domain do
  @moduledoc "The todo backend domain — its RPC-exposed surface."
  use Ash.Domain, extensions: [AshRemote.Rpc]

  resources do
    resource TodoServer.User
    resource TodoServer.TodoList
    resource TodoServer.Todo
  end

  rpc do
    resource TodoServer.Todo do
      expose :read
      expose :create
      expose :update
      expose :destroy
    end

    resource TodoServer.TodoList do
      expose :read
      expose :create
    end

    resource TodoServer.User do
      expose :read
      expose :create
    end
  end
end
