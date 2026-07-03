defmodule TodoClient.LiveTest do
  @moduledoc """
  End-to-end: drives the LiveView's callbacks against the backend's RPC router
  running in-process. Every assertion is data that round-tripped through the
  generated ash_remote resources → /rpc/run → the todo_server — including
  relationship loads, the `overdue?` calculation, and the list count aggregates.

  (Interactive rendering is exercised in a browser via `mix run --no-halt`;
  `Phoenix.LiveViewTest` needs `lazy_html`, which isn't available offline here,
  so this drives the callbacks directly.)
  """
  use ExUnit.Case, async: false

  alias TodoClient.Live

  setup do
    Enum.each(Ash.read!(TodoServer.Todo), &Ash.destroy!/1)
    Enum.each(Ash.read!(TodoServer.TodoList), &Ash.destroy!/1)
    Enum.each(Ash.read!(TodoServer.User), &Ash.destroy!/1)

    user = Ash.create!(TodoServer.User, %{name: "Ada"})
    list = Ash.create!(TodoServer.TodoList, %{name: "Errands", user_id: user.id})
    %{user: user, list: list}
  end

  defp mount do
    {:ok, socket} = Live.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = Live.handle_event(name, params, socket)
    socket
  end

  defp assigned_list(socket, id), do: Enum.find(socket.assigns.lists, &(&1.id == id))

  test "create, toggle, and delete round-trip to the server", %{list: list} do
    socket = mount()
    assert assigned_list(socket, list.id).todos == []

    socket = event(socket, "save", %{"todo" => %{"title" => "Walk the dog", "list_id" => list.id}})
    assert assigned_list(socket, list.id) |> Map.fetch!(:todos) |> Enum.map(& &1.title) == ["Walk the dog"]
    assert Enum.map(Ash.read!(TodoServer.Todo), & &1.title) == ["Walk the dog"]

    id = assigned_list(socket, list.id).todos |> hd() |> Map.fetch!(:id)

    socket = event(socket, "toggle", %{"id" => id})
    assert assigned_list(socket, list.id) |> Map.fetch!(:todos) |> hd() |> Map.fetch!(:completed)
    assert Ash.get!(TodoServer.Todo, id).completed == true

    socket = event(socket, "delete", %{"id" => id})
    assert assigned_list(socket, list.id).todos == []
    assert Ash.read!(TodoServer.Todo) == []
  end

  test "invalid create keeps the list empty and surfaces form errors", %{list: list} do
    socket = mount() |> event("save", %{"todo" => %{"title" => "", "list_id" => list.id}})
    assert assigned_list(socket, list.id).todos == []
    refute socket.assigns.form.source.valid?
  end

  test "the mirrored string_length validation rejects short titles client-side", %{list: list} do
    socket = mount() |> event("save", %{"todo" => %{"title" => "ab", "list_id" => list.id}})

    assert assigned_list(socket, list.id).todos == []
    assert Ash.read!(TodoServer.Todo) == []

    refute socket.assigns.form.source.valid?
    errors = AshPhoenix.Form.errors(socket.assigns.form.source)
    assert errors[:title]
  end

  test "relationships, calculation, and aggregates round-trip into assigns", %{list: list} do
    overdue =
      Ash.create!(TodoServer.Todo, %{
        title: "Renew passport",
        due_date: ~D[2020-01-01],
        list_id: list.id
      })

    done = Ash.create!(TodoServer.Todo, %{title: "Buy milk", completed: true, list_id: list.id})
    _sub = Ash.create!(TodoServer.Todo, %{title: "Book appointment", parent_id: overdue.id})

    socket = mount()
    loaded = assigned_list(socket, list.id)

    # belongs_to relationship on the list
    assert loaded.user.name == "Ada"

    # aggregates, computed server-side (the subtask has no list, so it doesn't count)
    assert loaded.todo_count == 2
    assert loaded.completed_count == 1

    # calculation — the client stub only names it; the server supplies the value
    todos_by_title = Map.new(loaded.todos, &{&1.title, &1})
    assert todos_by_title["Renew passport"].overdue? == true
    assert todos_by_title["Buy milk"].overdue? == false

    # self-referential relationship, nested one level under the list's todos
    assert Enum.map(todos_by_title["Renew passport"].subtasks, & &1.title) == ["Book appointment"]

    # aggregate freshness: completing a todo moves the count
    socket = event(socket, "toggle", %{"id" => overdue.id})
    assert assigned_list(socket, list.id).completed_count == 2
  end
end
