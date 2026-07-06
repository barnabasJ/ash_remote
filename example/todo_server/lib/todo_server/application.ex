defmodule TodoServer.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:todo_server, :port, 4010)

    children = [
      {Phoenix.PubSub, name: TodoServer.PubSub},
      {AshAuthentication.Supervisor, [otp_app: :todo_server]},
      TodoServer.Endpoint
    ]

    opts = [strategy: :one_for_one, name: TodoServer.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      seed()

      Logger.info(
        "todo_server on http://127.0.0.1:#{port} — RPC at /rpc/*, manifest at /manifest.json, " <>
          "socket at /ash_remote/socket. Demo users: ada@example.com / grace@example.com (password: password123)."
      )

      {:ok, pid}
    end
  end

  # Seed two demo users, each with a couple of todos, once, if the store is empty.
  defp seed do
    if Ash.count!(TodoServer.Accounts.User, authorize?: false) == 0 do
      ada = register("ada@example.com")
      grace = register("grace@example.com")

      errands = create_list(ada, "Errands", false)
      launch = create_list(grace, "Launch", false)
      announcements = create_list(ada, "Announcements", true)

      create_todo(ada, "Buy milk", :low, errands, false, false)
      create_todo(ada, "Renew passport", :medium, errands, false, false)
      create_todo(grace, "Ship ash_remote", :high, launch, false, false)
      create_todo(grace, "Write the changelog", :high, launch, false, false)
      create_todo(grace, "Draft README", :low, launch, false, true)
      # A shared/public todo — every signed-in user sees it and its live updates.
      create_todo(ada, "Company all-hands Friday", :medium, announcements, true, false)
    end
  rescue
    error -> Logger.warning("seed skipped: #{inspect(error)}")
  end

  defp register(email) do
    TodoServer.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: email,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_list(user, name, public) do
    TodoServer.TodoList
    |> Ash.Changeset.for_create(:create, %{name: name, public: public}, actor: user)
    |> Ash.create!(actor: user)
  end

  defp create_todo(user, title, priority, list, public, completed) do
    TodoServer.Todo
    |> Ash.Changeset.for_create(
      :create,
      %{
        title: title,
        priority: priority,
        list_id: list.id,
        public: public,
        completed: completed
      },
      actor: user
    )
    |> Ash.create!(actor: user)
  end
end
