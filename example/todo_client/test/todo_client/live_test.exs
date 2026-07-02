defmodule TodoClient.LiveTest do
  @moduledoc """
  End-to-end: drives the LiveView's callbacks against the backend's RPC router
  running in-process. Every assertion is data that round-tripped through the
  generated ash_remote resource → /rpc/run → the todo_server.

  (Interactive rendering is exercised in a browser via `mix run --no-halt`;
  `Phoenix.LiveViewTest` needs `lazy_html`, which isn't available offline here,
  so this drives the callbacks directly.)
  """
  use ExUnit.Case, async: false

  alias TodoClient.Live

  setup do
    Enum.each(Ash.read!(TodoServer.Todo), &Ash.destroy!/1)
    :ok
  end

  defp mount do
    {:ok, socket} = Live.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = Live.handle_event(name, params, socket)
    socket
  end

  test "create, toggle, and delete round-trip to the server" do
    socket = mount()
    assert socket.assigns.todos == []

    socket = event(socket, "save", %{"todo" => %{"title" => "Walk the dog"}})
    assert Enum.map(socket.assigns.todos, & &1.title) == ["Walk the dog"]
    assert Enum.map(Ash.read!(TodoServer.Todo), & &1.title) == ["Walk the dog"]

    id = hd(socket.assigns.todos).id

    socket = event(socket, "toggle", %{"id" => id})
    assert Enum.find(socket.assigns.todos, &(&1.id == id)).completed == true
    assert Ash.get!(TodoServer.Todo, id).completed == true

    socket = event(socket, "delete", %{"id" => id})
    assert socket.assigns.todos == []
    assert Ash.read!(TodoServer.Todo) == []
  end

  test "invalid create keeps the list empty and surfaces form errors" do
    socket = mount() |> event("save", %{"todo" => %{"title" => ""}})
    assert socket.assigns.todos == []
    refute socket.assigns.form.source.valid?
  end
end
