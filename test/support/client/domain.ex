defmodule AshRemote.Client.Domain do
  @moduledoc "Client-side domain for the hand-written M2 mirror resources."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshRemote.Client.User
    resource AshRemote.Client.Todo
    resource AshRemote.Client.Comment
  end
end
