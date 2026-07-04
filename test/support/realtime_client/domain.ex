defmodule AshRemote.RealtimeClient.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshRemote.RealtimeClient.Todo)
    resource(AshRemote.RealtimeClient.PubSubTodo)
    resource(AshRemote.RealtimeClient.Document)
  end
end
