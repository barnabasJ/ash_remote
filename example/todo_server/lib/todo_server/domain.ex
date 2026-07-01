defmodule TodoServer.Domain do
  @moduledoc "The todo backend domain — its RPC-exposed surface."
  use Ash.Domain

  resources do
    resource TodoServer.User
    resource TodoServer.Todo
  end
end
