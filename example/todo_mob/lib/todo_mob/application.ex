defmodule TodoMob.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # The real mob framework owns the on-device supervision tree and screen
    # lifecycle; nothing to start here for the headless demo.
    Supervisor.start_link([], strategy: :one_for_one, name: TodoMob.Supervisor)
  end
end
