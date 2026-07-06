defmodule TodoClient.LiveTest do
  @moduledoc """
  End-to-end: drives the LiveView's callbacks against the backend (auth + RPC)
  running in-process. The client is signed in as ada (`TodoClient.Session`), so
  every read/write round-trips through the generated ash_remote resources →
  authenticated `/rpc/run` → todo_server, scoped by the owner-or-public policy.

  (`Phoenix.LiveViewTest` needs `lazy_html`, unavailable offline here, so this
  drives the callbacks directly. Interactive + realtime cross-client behavior
  is exercised in a real browser — see example/README.md — since two
  independent caches need two real OS processes, not two structs in one test.)
  """
  use TodoClient.Case, async: false

  defp mount do
    # `assigns.flash` isn't populated on a bare socket (only the real
    # connect/mount pipeline does that) — put_flash/3 needs it to exist.
    bare_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    {:ok, socket} = TodoClient.Live.mount(%{}, %{}, bare_socket)
    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = TodoClient.Live.handle_event(name, params, socket)
    socket
  end

  defp assigned_list(socket, id), do: Enum.find(socket.assigns.lists, &(&1.id == id))

  defp titles(socket, id),
    do: assigned_list(socket, id).todos |> Enum.map(& &1.title) |> Enum.sort()

  test "create/toggle/delete round-trip as the signed-in user", %{list: list} do
    socket = mount()
    assert assigned_list(socket, list.id).todos == []

    socket =
      event(socket, "save", %{"todo" => %{"title" => "Walk the dog", "list_id" => list.id}})

    assert titles(socket, list.id) == ["Walk the dog"]
    assert Enum.map(Ash.read!(TodoServer.Todo, authorize?: false), & &1.title) == ["Walk the dog"]

    todo = assigned_list(socket, list.id).todos |> hd()
    socket = event(socket, "toggle", %{"id" => todo.id})
    assert assigned_list(socket, list.id).todos |> hd() |> Map.fetch!(:completed)

    socket = event(socket, "delete", %{"id" => todo.id})
    assert assigned_list(socket, list.id).todos == []
    assert Ash.read!(TodoServer.Todo, authorize?: false) == []
  end

  test "deleting a row a different actor already destroyed self-heals instead of crashing", %{
    list: list
  } do
    # Owner-or-public: needs to be public for a different actor to destroy it.
    ghost =
      server_create_todo!(%{title: "Ghost item", list_id: list.id, public: true})

    socket = mount()
    assert titles(socket, list.id) == ["Ghost item"]

    # A different actor destroys it directly on the server. This test's
    # AshRemote.Realtime tree is never started (test config: start_children:
    # false), so ada's client never processes any notification for this —
    # the same end state as a genuinely dropped broadcast on an otherwise
    # healthy connection (see AshRemote.MultiDatalayer.LifecycleGuard's moduledoc
    # on notification delivery being best-effort, not "the connection died").
    grace = register!("grace-ghost@example.com")
    ghost |> Ash.Changeset.for_destroy(:destroy, %{}, actor: grace) |> Ash.destroy!(actor: grace)

    # Still cached — a plain reload shows the ghost, exactly like the bug
    # report: the coverage ledger has no reason to know it's stale.
    assert titles(mount(), list.id) == ["Ghost item"]

    socket = event(socket, "delete", %{"id" => ghost.id})

    assert assigned_list(socket, list.id).todos == []
    assert Phoenix.Flash.get(socket.assigns.flash, :info) =~ "already removed"

    # The self-heal must be real invalidation, not just this one socket's
    # assigns — a completely fresh mount must also no longer show the ghost.
    # (Ledger invalidation alone isn't enough here: ash_multi_datalayer's
    # remainder-read optimization can resurrect a physically-still-cached
    # row via a *different*, unrelated entry's coverage — this only holds
    # because AshMultiDatalayer.forget!/3 also evicts the physical row, not
    # just the matching ledger entries.)
    assert titles(mount(), list.id) == []
  end

  test "toggling a row a different actor already destroyed self-heals instead of crashing", %{
    list: list
  } do
    ghost = server_create_todo!(%{title: "Ghost item", list_id: list.id, public: true})
    socket = mount()

    grace = register!("grace-ghost2@example.com")
    ghost |> Ash.Changeset.for_destroy(:destroy, %{}, actor: grace) |> Ash.destroy!(actor: grace)

    socket = event(socket, "toggle", %{"id" => ghost.id})

    assert assigned_list(socket, list.id).todos == []
    assert Phoenix.Flash.get(socket.assigns.flash, :info) =~ "already removed"
  end

  test "a new todo inherits its list's public flag", %{list: list, other_list: other_list} do
    public_list =
      TodoClient.Remote.TodoList
      |> Ash.Changeset.for_create(:create, %{name: "Shared", public: true},
        actor: TodoClient.Session.actor()
      )
      |> Ash.create!(actor: TodoClient.Session.actor())

    socket =
      mount()
      |> event("save", %{"todo" => %{"title" => "Private one", "list_id" => list.id}})
      |> event("save", %{"todo" => %{"title" => "Public one", "list_id" => public_list.id}})

    private = assigned_list(socket, list.id).todos |> hd()
    public = assigned_list(socket, public_list.id).todos |> hd()

    refute private.public
    assert public.public
    assert assigned_list(socket, other_list.id).todos == []
  end

  test "the mirrored string_length validation rejects short titles client-side", %{list: list} do
    socket = mount() |> event("save", %{"todo" => %{"title" => "ab", "list_id" => list.id}})

    assert assigned_list(socket, list.id).todos == []
    assert Ash.read!(TodoServer.Todo, authorize?: false) == []
    refute socket.assigns.form.source.valid?
  end

  test "the view shows only the user's own lists plus public ones from another user", %{
    ada: ada
  } do
    grace = register!("grace2@example.com")

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
    assert ada.email |> to_string() == "ada@example.com"
    assert private.public == false and public.public == true
  end

  test "relationships, calculation, and both aggregates round-trip into assigns", %{list: list} do
    overdue =
      server_create_todo!(%{title: "Renew passport", due_date: ~D[2020-01-01], list_id: list.id})

    server_create_todo!(%{title: "Buy milk", completed: true, list_id: list.id})
    server_create_todo!(%{title: "Book appointment", parent_id: overdue.id, list_id: list.id})

    socket = mount()
    loaded = assigned_list(socket, list.id)

    assert loaded.todo_count == 3
    assert loaded.completed_count == 1

    todos_by_title = Map.new(loaded.todos, &{&1.title, &1})
    assert todos_by_title["Renew passport"].overdue? == true
    assert todos_by_title["Buy milk"].overdue? == false
    assert Enum.map(todos_by_title["Renew passport"].subtasks, & &1.title) == ["Book appointment"]

    socket = event(socket, "toggle", %{"id" => overdue.id})
    assert assigned_list(socket, list.id).completed_count == 2
  end

  test "the browse panel filters by status and priority", %{list: list} do
    server_create_todo!(%{title: "Open low", list_id: list.id, priority: :low})
    server_create_todo!(%{title: "Done high", list_id: list.id, completed: true, priority: :high})

    socket = mount() |> event("browse-list", %{"browse_list" => list.id})

    all = socket.assigns.browse_todos |> Enum.map(& &1.title) |> Enum.sort()
    assert all == ["Done high", "Open low"]

    active =
      event(socket, "browse-status", %{"status" => "active"}).assigns.browse_todos
      |> Enum.map(& &1.title)

    assert active == ["Open low"]

    high_priority =
      socket
      |> event("browse-priority", %{"priority" => "high"})
      |> Map.fetch!(:assigns)
      |> Map.fetch!(:browse_todos)
      |> Enum.map(& &1.title)

    assert high_priority == ["Done high"]
  end
end
