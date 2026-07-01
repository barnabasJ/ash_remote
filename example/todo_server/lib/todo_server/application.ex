defmodule TodoServer.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:todo_server, :port, 4000)

    children = [
      {Bandit, plug: TodoServer.Rpc.Router, port: port}
    ]

    opts = [strategy: :one_for_one, name: TodoServer.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      seed()
      Logger.info("todo_server listening on http://127.0.0.1:#{port} (manifest at /manifest.json)")
      {:ok, pid}
    end
  end

  # Seed a demo user + todos once, if the store is empty.
  defp seed do
    if Ash.count!(TodoServer.Todo) == 0 do
      user = Ash.create!(TodoServer.User, %{name: "Ada"})

      Ash.create!(TodoServer.Todo, %{title: "Buy milk", priority: :low, user_id: user.id})
      Ash.create!(TodoServer.Todo, %{title: "Ship ash_remote", priority: :high, user_id: user.id})
    end
  rescue
    error -> Logger.warning("seed skipped: #{inspect(error)}")
  end
end
