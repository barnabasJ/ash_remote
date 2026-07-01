defmodule TodoMob.Remote.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(TodoMob.Remote.Todo)
    resource(TodoMob.Remote.User)
  end
end
