defmodule TodoClient.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # The LiveView server is started explicitly via `TodoClient.Web.start/1`.
    Supervisor.start_link([], strategy: :one_for_one, name: TodoClient.Supervisor)
  end
end
