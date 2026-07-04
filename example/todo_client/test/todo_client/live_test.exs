defmodule TodoClient.LiveTest do
  @moduledoc """
  End-to-end: drives the LiveView's callbacks against the backend (auth + RPC)
  running in-process. The client is signed in as ada (`TodoClient.Session`), so
  every read/write round-trips through the generated ash_remote resources →
  authenticated `/rpc/run` → todo_server, scoped by the owner policy.

  (`Phoenix.LiveViewTest` needs `lazy_html`, unavailable offline here, so this
  drives the callbacks directly. Interactive + realtime behavior is exercised in
  a browser via `mix run --no-halt` — see example/README.md.)
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias TodoClient.Live

  setup do
    ada =
      TodoServer.Accounts.User
      |> Ash.Query.filter(email == "ada@example.com")
      |> Ash.read_one!(authorize?: false)

    Enum.each(Ash.read!(TodoServer.Todo, authorize?: false), &Ash.destroy!(&1, authorize?: false))

    Enum.each(
      Ash.read!(TodoServer.TodoList, authorize?: false),
      &Ash.destroy!(&1, authorize?: false)
    )

    list =
      TodoServer.TodoList
      |> Ash.Changeset.for_create(:create, %{name: "Errands"}, actor: ada)
      |> Ash.create!(actor: ada)

    %{ada: ada, list: list}
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

  defp titles(socket, id),
    do: assigned_list(socket, id).todos |> Enum.map(& &1.title) |> Enum.sort()

  test "authenticated create/toggle/delete round-trip as the signed-in user", %{list: list} do
    socket = mount()
    assert assigned_list(socket, list.id).todos == []

    socket = event(socket, "add_todo", %{"title" => "Walk the dog", "list_id" => list.id})
    assert titles(socket, list.id) == ["Walk the dog"]
    assert Enum.map(Ash.read!(TodoServer.Todo, authorize?: false), & &1.title) == ["Walk the dog"]

    todo = assigned_list(socket, list.id).todos |> hd()
    socket = event(socket, "toggle", %{"id" => todo.id, "completed" => "false"})
    assert assigned_list(socket, list.id).todos |> hd() |> Map.fetch!(:completed)

    socket = event(socket, "delete", %{"id" => todo.id})
    assert assigned_list(socket, list.id).todos == []
    assert Ash.read!(TodoServer.Todo, authorize?: false) == []
  end

  test "the mirrored string_length validation rejects short titles", %{list: list} do
    socket = mount() |> event("add_todo", %{"title" => "ab", "list_id" => list.id})

    assert assigned_list(socket, list.id).todos == []
    assert Ash.read!(TodoServer.Todo, authorize?: false) == []
  end

  test "the view shows only the user's own lists plus public ones", %{ada: ada} do
    # A second user's private list is not visible; a public one is.
    grace = register_and_get("grace2@example.com")

    private =
      TodoServer.TodoList
      |> Ash.Changeset.for_create(:create, %{name: "Grace private"}, actor: grace)
      |> Ash.create!(actor: grace)

    public =
      TodoServer.TodoList
      |> Ash.Changeset.for_create(:create, %{name: "Grace public", public: true}, actor: grace)
      |> Ash.create!(actor: grace)

    names = mount().assigns.lists |> Enum.map(& &1.name)

    assert "Grace public" in names
    refute "Grace private" in names
    # sanity: ada is the signed-in user
    assert ada.email |> to_string() == "ada@example.com"
    assert private.public == false and public.public == true
  end

  defp register_and_get(email) do
    Req.post!("http://127.0.0.1:4998/auth/register",
      json: %{email: email, password: "password123"}
    )

    TodoServer.Accounts.User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one!(authorize?: false)
  end
end
