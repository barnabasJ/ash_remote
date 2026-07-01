defmodule TodoClient.Web do
  @moduledoc """
  Boots the LiveView UI (a minimal Phoenix endpoint).

      # in one shell — the backend:
      cd example/todo_server && mix run --no-halt

      # in another — the LiveView client, then open http://localhost:4001:
      cd example/todo_client && mix run --no-halt -e "TodoClient.Web.start()"
  """

  @doc "Start the LiveView server (defaults to port 4001)."
  def start(port \\ 4001) do
    config =
      Application.get_env(:todo_client, TodoClient.Endpoint, [])
      |> Keyword.merge(http: [ip: {127, 0, 0, 1}, port: port], server: true)

    Application.put_env(:todo_client, TodoClient.Endpoint, config)

    children = [
      {Phoenix.PubSub, name: TodoClient.PubSub},
      TodoClient.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: TodoClient.Web.Supervisor)
  end
end
