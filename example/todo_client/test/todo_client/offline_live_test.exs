defmodule TodoClient.OfflineLiveTest do
  use TodoClient.Case, async: false

  alias TodoClient.Local.{Todo, TodoList}
  alias AshMultiDatalayer.Orchestrator.LocalOutbox

  setup_all do
    db =
      Path.join(System.tmp_dir!(), "todo-client-offline-#{System.unique_integer([:positive])}.db")

    start_supervised!({TodoClient.Repo, database: db})
    TodoClient.Repo.Migrations.migrate!()
    start_supervised!({Oban, Application.fetch_env!(:todo_client, Oban)})

    on_exit(fn ->
      File.rm(db)
      File.rm(db <> "-shm")
      File.rm(db <> "-wal")
    end)

    :ok
  end

  setup do
    for table <- ["oban_jobs", "outbox_entries", "local_todos", "local_todo_lists"] do
      Ecto.Adapters.SQL.query!(TodoClient.Repo, "DELETE FROM #{table}")
    end

    :ok
  end

  defp mount do
    bare_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    {:ok, socket} = TodoClient.OfflineLive.mount(%{}, %{}, bare_socket)
    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = TodoClient.OfflineLive.handle_event(name, params, socket)
    socket
  end

  test "creates a list and public and private todos in local storage" do
    socket = mount() |> event("add_list", %{"name" => "Weekend", "public" => "true"})
    list = Enum.find(socket.assigns.lists, &(&1.name == "Weekend"))
    assert list.public

    socket =
      socket
      |> event("save", %{
        "todo" => %{"title" => "Share plans", "list_id" => list.id, "public" => "true"}
      })
      |> event("save", %{
        "todo" => %{"title" => "Buy gift", "list_id" => list.id, "public" => "false"}
      })

    assert Enum.find(socket.assigns.todos, &(&1.title == "Share plans")).public
    refute Enum.find(socket.assigns.todos, &(&1.title == "Buy gift")).public
    assert Enum.all?(socket.assigns.todos, &(&1.list_id == list.id))
    assert length(LocalOutbox.pending(TodoList)) == 1
    assert length(LocalOutbox.pending(Todo)) == 2

    Oban.drain_queue(queue: :todo_sync, with_scheduled: true)

    assert LocalOutbox.pending(TodoList) == []
    assert LocalOutbox.pending(Todo) == []
    assert Enum.any?(Ash.read!(TodoServer.TodoList, authorize?: false), &(&1.id == list.id))

    assert Enum.count(Ash.read!(TodoServer.Todo, authorize?: false), &(&1.list_id == list.id)) ==
             2

    html =
      socket.assigns
      |> TodoClient.OfflineLive.render()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ "Weekend"
    assert html =~ "Share plans"
    assert html =~ "Buy gift"
  end
end
