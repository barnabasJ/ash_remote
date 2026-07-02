defmodule TodoClient.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: TodoClient.PubSub},
      TodoClient.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: TodoClient.Supervisor)
  end
end
