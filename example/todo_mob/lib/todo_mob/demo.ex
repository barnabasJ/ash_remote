defmodule TodoMob.Demo do
  @moduledoc """
  Drives `TodoMob.TodoListScreen` headlessly against a running todo_server,
  exercising the full screen → ash_remote → RPC → server loop. Raises on any
  mismatch, so it doubles as an end-to-end smoke check (see `example/e2e.sh`).
  """

  alias TodoMob.TodoListScreen, as: Screen

  def run do
    {:ok, _} = Application.ensure_all_started(:todo_mob)

    socket = Mob.Screen.mount(Screen)
    titles = titles(socket)
    log("mounted", titles)
    assert!("Buy milk" in titles, "seeded todo missing")

    # Create via AshPhoenix.Form (client-side) → remote create over RPC.
    socket = Mob.Screen.dispatch(Screen, socket, {:change, %{"title" => "Walk the dog"}})
    socket = Mob.Screen.dispatch(Screen, socket, {:tap, :create})
    log("after create", titles(socket))
    assert!("Walk the dog" in titles(socket), "create did not round-trip")

    walk = Enum.find(socket.assigns.todos, &(&1.title == "Walk the dog"))

    # Toggle complete (custom :complete action) over RPC.
    socket = Mob.Screen.dispatch(Screen, socket, {:tap, {:toggle, walk.id}})
    toggled = Enum.find(socket.assigns.todos, &(&1.id == walk.id))
    log("after toggle", %{completed: toggled.completed})
    assert!(toggled.completed == true, "toggle did not complete the todo")

    # Delete over RPC.
    socket = Mob.Screen.dispatch(Screen, socket, {:tap, {:delete, walk.id}})
    log("after delete", titles(socket))
    assert!("Walk the dog" not in titles(socket), "delete did not round-trip")

    IO.puts("\n✅ mob ⇄ ash_remote ⇄ todo_server e2e OK")
  end

  defp titles(socket), do: Enum.map(socket.assigns.todos, & &1.title)

  defp log(step, value), do: IO.puts("• #{step}: #{inspect(value)}")

  defp assert!(true, _message), do: :ok
  defp assert!(_false, message), do: raise("assertion failed: #{message}")
end
