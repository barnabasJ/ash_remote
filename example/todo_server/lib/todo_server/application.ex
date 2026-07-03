defmodule TodoServer.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:todo_server, :port, 4010)

    children = [
      {Bandit, plug: TodoServer.RpcRouter, port: port}
    ]

    opts = [strategy: :one_for_one, name: TodoServer.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      seed()
      Logger.info("todo_server listening on http://127.0.0.1:#{port} (manifest at /manifest.json)")
      {:ok, pid}
    end
  end

  # Seed demo users, lists and todos once, if the store is empty.
  defp seed do
    if Ash.count!(TodoServer.Todo) == 0 do
      ada = Ash.create!(TodoServer.User, %{name: "Ada"})
      grace = Ash.create!(TodoServer.User, %{name: "Grace"})

      errands = Ash.create!(TodoServer.TodoList, %{name: "Errands", user_id: ada.id})
      launch = Ash.create!(TodoServer.TodoList, %{name: "Launch", user_id: grace.id})

      Ash.create!(TodoServer.Todo, %{title: "Buy milk", priority: :low, list_id: errands.id})

      Ash.create!(TodoServer.Todo, %{
        title: "Renew passport",
        priority: :medium,
        due_date: ~D[2020-01-01],
        list_id: errands.id
      })

      Ash.create!(TodoServer.Todo, %{
        title: "Pick a name",
        priority: :medium,
        completed: true,
        list_id: launch.id
      })

      ship = Ash.create!(TodoServer.Todo, %{title: "Ship ash_remote", priority: :high, list_id: launch.id})

      Ash.create!(TodoServer.Todo, %{title: "Write the changelog", priority: :high, parent_id: ship.id})
      Ash.create!(TodoServer.Todo, %{title: "Tag the release", priority: :medium, parent_id: ship.id})
    end
  rescue
    error -> Logger.warning("seed skipped: #{inspect(error)}")
  end
end
