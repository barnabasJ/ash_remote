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

  defp todo_read_decisions(acc \\ []) do
    receive do
      {:mdl, [:ash_multi_datalayer, :read, kind], _, %{resource: Todo}}
      when kind in [:hit, :miss, :partial] ->
        todo_read_decisions([kind | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

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

  test "online page keeps covered reads while offline and catches up on reconnect", %{
    ada: ada,
    list: list
  } do
    todo = server_create_todo!(%{title: "Cached todo", list_id: list.id})
    socket = mount()
    assert titles(socket, list.id) == ["Cached todo"]

    socket = event(socket, "network-toggle", %{})
    assert socket.assigns.offline?
    rpc_count = CountingRouter.rpc_count()

    # A new LiveView must really read through the cache while RPC is blocked.
    assert titles(mount(), list.id) == ["Cached todo"]
    assert CountingRouter.rpc_count() == rpc_count

    assert {:error, _} =
             Todo
             |> Ash.Changeset.for_create(:create, %{title: "Blocked RPC", list_id: list.id},
               actor: TodoClient.Session.actor()
             )
             |> Ash.create(actor: TodoClient.Session.actor())

    socket =
      event(socket, "save", %{"todo" => %{"title" => "Cannot write", "list_id" => list.id}})

    assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "Write failed"
    assert CountingRouter.rpc_count() == rpc_count
    assert Enum.map(Ash.read!(TodoServer.Todo, authorize?: false), & &1.title) == ["Cached todo"]

    socket = event(socket, "toggle", %{"id" => todo.id})
    assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "Write failed"
    refute assigned_list(socket, list.id).todos |> hd() |> Map.fetch!(:completed)

    todo
    |> Ash.Changeset.for_update(:update, %{title: "Changed while offline"}, actor: ada)
    |> Ash.update!(actor: ada)

    assert titles(mount(), list.id) == ["Cached todo"]

    socket = event(socket, "network-toggle", %{})
    refute socket.assigns.offline?
    assert Phoenix.Flash.get(socket.assigns.flash, :error) == nil
    assert titles(socket, list.id) == ["Cached todo"]
    assert titles(mount(), list.id) == ["Changed while offline"]

    # The old LiveView keeps its assigned rows until it makes another read.
    socket = event(socket, "cache-toggle", %{})
    assert titles(socket, list.id) == ["Changed while offline"]
    socket = event(socket, "cache-toggle", %{})

    socket =
      event(socket, "save", %{"todo" => %{"title" => "Online again", "list_id" => list.id}})

    assert titles(socket, list.id) == ["Changed while offline", "Online again"]
  end

  test "a stale online page rejects updates and deletes after reconnect", %{list: list} do
    todo = server_create_todo!(%{title: "Shared todo", list_id: list.id, public: true})
    socket = mount()

    socket = event(socket, "network-toggle", %{})

    todo
    |> Ash.Changeset.for_update(:update, %{title: "Changed by Grace", version: 2},
      actor: TodoClient.Session.actor()
    )
    |> Ash.update!(actor: TodoClient.Session.actor())

    socket = event(socket, "network-toggle", %{})
    socket = event(socket, "toggle", %{"id" => todo.id})

    assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "Conflict"
    refute Ash.get!(TodoServer.Todo, todo.id, authorize?: false).completed
    assert titles(socket, list.id) == ["Changed by Grace"]

    # A fresh display can write; a second stale display cannot delete it.
    stale_socket = mount()
    fresh = Ash.get!(TodoServer.Todo, todo.id, authorize?: false)

    fresh
    |> Ash.Changeset.for_update(:update, %{title: "Changed again", version: 3},
      actor: TodoClient.Session.actor()
    )
    |> Ash.update!(actor: TodoClient.Session.actor())

    stale_socket = event(stale_socket, "delete", %{"id" => todo.id})
    assert Phoenix.Flash.get(stale_socket.assigns.flash, :error) =~ "Conflict"
    assert titles(stale_socket, list.id) == ["Changed again"]
    assert Ash.get!(TodoServer.Todo, todo.id, authorize?: false).title == "Changed again"
  end

  test "the server serializes competing version-checked writes", %{ada: ada, list: list} do
    todo = server_create_todo!(%{title: "Shared todo", list_id: list.id})

    results =
      1..2
      |> Task.async_stream(
        fn n ->
          todo
          |> Ash.Changeset.for_update(
            :update,
            %{title: "Edit #{n}", version: 2, expected_version: 1},
            actor: ada
          )
          |> Ash.update(actor: ada)
        end,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert Ash.get!(TodoServer.Todo, todo.id, authorize?: false).version == 2
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

  test "loaded todos provide counts and the overdue calculation", %{list: list} do
    overdue =
      server_create_todo!(%{title: "Renew passport", due_date: ~D[2020-01-01], list_id: list.id})

    server_create_todo!(%{title: "Buy milk", completed: true, list_id: list.id})
    socket = mount()
    loaded = assigned_list(socket, list.id)

    assert loaded.todo_count == 2
    assert loaded.completed_count == 1

    todos_by_title = Map.new(loaded.todos, &{&1.title, &1})
    assert todos_by_title["Renew passport"].overdue? == true
    assert todos_by_title["Buy milk"].overdue? == false
    socket = event(socket, "toggle", %{"id" => overdue.id})
    assert assigned_list(socket, list.id).completed_count == 2
  end

  test "the browse panel filters by status and priority", %{list: list} do
    server_create_todo!(%{title: "Open low", list_id: list.id, priority: :low})
    server_create_todo!(%{title: "Done high", list_id: list.id, completed: true, priority: :high})

    socket = mount() |> event("browse-list", %{"browse_list" => list.id})
    rpc_count = CountingRouter.rpc_count()
    todo_read_decisions()

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
    assert CountingRouter.rpc_count() == rpc_count
    assert todo_read_decisions() == []
  end

  test "a just-refreshed todo shows the source that supplied its new value", %{list: list} do
    server_create_todo!(%{title: "Fresh remote value", list_id: list.id})

    socket = mount()
    todo = assigned_list(socket, list.id).todos |> hd()

    assert Ash.Resource.get_metadata(todo, :served_from_layer) == AshRemote.DataLayer
    assert socket.assigns.browse_todos == assigned_list(socket, list.id).todos
  end

  test "a realtime change stays marked as server-supplied until another read", %{
    ada: ada,
    list: list
  } do
    todo = server_create_todo!(%{title: "Before change", list_id: list.id})
    socket = mount()
    todo_read_decisions()

    todo
    |> Ash.Changeset.for_update(:update, %{title: "After change"}, actor: ada)
    |> Ash.update!(actor: ada)

    AshMultiDatalayer.forget!(Todo, %{id: todo.id})

    {:noreply, socket} =
      TodoClient.Live.handle_info({:remote_change, Todo, :update, todo.id}, socket)

    refreshed = assigned_list(socket, list.id).todos |> hd()
    assert refreshed.title == "After change"
    assert Ash.Resource.get_metadata(refreshed, :served_from_layer) == AshRemote.DataLayer
    assert socket.assigns.browse_todos == assigned_list(socket, list.id).todos
    assert todo_read_decisions() == [:miss]
    assert MapSet.member?(socket.assigns.remote_updated_ids, todo.id)

    html =
      socket.assigns
      |> TodoClient.Live.render()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ "remote update"

    socket = event(socket, "browse-status", %{"status" => "all"})
    refute MapSet.member?(socket.assigns.remote_updated_ids, todo.id)
  end

  test "a broader list filter uses cached rows and fetches only the uncovered list", %{
    list: list,
    other_list: other_list
  } do
    server_create_todo!(%{title: "Cached", list_id: list.id})
    server_create_todo!(%{title: "Remote", list_id: other_list.id})
    actor = TodoClient.Session.actor()

    Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!(actor: actor)
    rpc_count = CountingRouter.rpc_count()
    list_ids = [list.id, other_list.id]

    rows =
      Todo
      |> Ash.Query.filter(list_id in ^list_ids)
      |> Ash.read!(actor: actor)

    titles = rows |> Enum.map(& &1.title) |> Enum.sort()

    assert titles == ["Cached", "Remote"]

    assert rows
           |> Enum.find(&(&1.title == "Cached"))
           |> Ash.Resource.get_metadata(:served_from_layer) == Ash.DataLayer.Ets

    assert rows
           |> Enum.find(&(&1.title == "Remote"))
           |> Ash.Resource.get_metadata(:served_from_layer) == AshRemote.DataLayer

    assert CountingRouter.rpc_count() == rpc_count + 1
    assert_receive {:mdl, [_, :read, :partial], _, %{cached: 1, fetched: 1}}
  end

  test "a disjoint list filter reads remotely without reporting a split", %{
    list: list,
    other_list: other_list
  } do
    server_create_todo!(%{title: "First", list_id: list.id})
    server_create_todo!(%{title: "Second", list_id: other_list.id})
    actor = TodoClient.Session.actor()

    Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!(actor: actor)
    rpc_count = CountingRouter.rpc_count()

    titles =
      Todo
      |> Ash.Query.filter(list_id == ^other_list.id)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.title)

    assert titles == ["Second"]
    assert CountingRouter.rpc_count() == rpc_count + 1
    assert_receive {:mdl, [_, :read, :miss], _, _}
    refute_receive {:mdl, [_, :read, :partial], _, _}
  end
end
