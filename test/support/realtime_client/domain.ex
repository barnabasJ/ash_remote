defmodule AshRemote.RealtimeClient.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshRemote.RealtimeClient.Todo)
  end
end
