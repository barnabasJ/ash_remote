defmodule TodoMob.TodoListScreenTest do
  @moduledoc """
  End-to-end: drives the mob screen (headless) against the backend's RPC router
  running in-process. Every assertion below is data that made a round trip
  through the generated ash_remote resource → /rpc/run → the todo_server.
  """
  use ExUnit.Case, async: false

  alias TodoMob.TodoListScreen, as: Screen

  setup do
    # Fresh backend state per test.
    Enum.each(Ash.read!(TodoServer.Todo), &Ash.destroy!/1)
    :ok
  end

  defp titles(socket), do: socket.assigns.todos |> Enum.map(& &1.title) |> Enum.sort()

  test "mount reads todos from the server (empty to start)" do
    socket = Mob.Screen.mount(Screen)
    assert socket.assigns.todos == []
    assert %AshPhoenix.Form{} = socket.assigns.form
  end

  test "create via AshPhoenix.Form round-trips to the server" do
    socket = Mob.Screen.mount(Screen)

    socket = Mob.Screen.dispatch(Screen, socket, {:change, %{"title" => "Walk the dog"}})
    socket = Mob.Screen.dispatch(Screen, socket, {:tap, :create})

    assert titles(socket) == ["Walk the dog"]
    # confirm it truly persisted on the backend, not just client state
    assert Enum.map(Ash.read!(TodoServer.Todo), & &1.title) == ["Walk the dog"]
  end

  test "toggle completes and reopens via the update action" do
    socket = Mob.Screen.mount(Screen)
    socket = Mob.Screen.dispatch(Screen, socket, {:change, %{"title" => "Ship it"}})
    socket = Mob.Screen.dispatch(Screen, socket, {:tap, :create})
    todo = hd(socket.assigns.todos)

    socket = Mob.Screen.dispatch(Screen, socket, {:tap, {:toggle, todo.id}})
    assert Enum.find(socket.assigns.todos, &(&1.id == todo.id)).completed == true

    socket = Mob.Screen.dispatch(Screen, socket, {:tap, {:toggle, todo.id}})
    assert Enum.find(socket.assigns.todos, &(&1.id == todo.id)).completed == false
  end

  test "delete round-trips to the server" do
    socket = Mob.Screen.mount(Screen)
    socket = Mob.Screen.dispatch(Screen, socket, {:change, %{"title" => "Temp"}})
    socket = Mob.Screen.dispatch(Screen, socket, {:tap, :create})
    todo = hd(socket.assigns.todos)

    socket = Mob.Screen.dispatch(Screen, socket, {:tap, {:delete, todo.id}})
    assert socket.assigns.todos == []
    assert Ash.read!(TodoServer.Todo) == []
  end

  test "invalid create surfaces form errors (no round trip)" do
    socket = Mob.Screen.mount(Screen)
    # blank title violates the required title; client-side form validation
    # rejects it before any RPC is sent.
    socket = Mob.Screen.dispatch(Screen, socket, {:change, %{"title" => ""}})
    socket = Mob.Screen.dispatch(Screen, socket, {:tap, :create})

    assert socket.assigns.todos == []
    refute socket.assigns.form.valid?
  end
end
