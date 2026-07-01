defmodule AshRemote.Backend.Domain do
  @moduledoc "Reference backend domain — the RPC-exposed surface for tests."
  use Ash.Domain

  resources do
    resource AshRemote.Backend.User
    resource AshRemote.Backend.Todo
    resource AshRemote.Backend.Comment
  end
end
