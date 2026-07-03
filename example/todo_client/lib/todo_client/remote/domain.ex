defmodule TodoClient.Remote.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(TodoClient.Remote.Todo)
    resource(TodoClient.Remote.TodoList)
    resource(TodoClient.Remote.User)
  end
end
