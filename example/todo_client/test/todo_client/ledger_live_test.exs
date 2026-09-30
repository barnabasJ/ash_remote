defmodule TodoClient.LedgerLiveTest do
  use TodoClient.Case, async: false

  test "shows the current coverage without making a remote read", %{list: list} do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
    {:ok, socket} = TodoClient.LedgerLive.mount(%{}, %{}, socket)
    assert socket.assigns.total == 0
    Phoenix.PubSub.subscribe(TodoClient.PubSub, TodoClient.CacheStats.topic())
    expected_backfills = TodoClient.CacheStats.stats().backfills + 1

    server_create_todo!(%{title: "Visible todo", list_id: list.id})

    Todo
    |> Ash.Query.filter(list_id == ^list.id)
    |> Ash.read!(actor: TodoClient.Session.actor())

    Todo
    |> Ash.Query.filter(list_id == ^list.id)
    |> Ash.read!(actor: TodoClient.Session.actor())

    assert_receive {:cache_stats, %{backfills: ^expected_backfills}}, 1_000
    {:noreply, socket} = TodoClient.LedgerLive.handle_info({:cache_stats, %{}}, socket)
    rpc_count = CountingRouter.rpc_count()

    assert socket.assigns.total >= 1

    assert Enum.any?(socket.assigns.resources, fn resource ->
             resource.label == "Todos" and
               Enum.any?(resource.entries, &String.contains?(&1.filter, "list_id"))
           end)

    key =
      socket.assigns.resources
      |> Enum.find(&(&1.label == "Todos"))
      |> Map.fetch!(:entries)
      |> hd()
      |> Map.fetch!(:key)

    {:noreply, socket} =
      TodoClient.LedgerLive.handle_event("toggle-entry", %{"key" => key}, socket)

    assert MapSet.member?(socket.assigns.open_entries, key)

    {:noreply, socket} = TodoClient.LedgerLive.handle_event("refresh", %{}, socket)
    assert MapSet.member?(socket.assigns.open_entries, key)

    {:noreply, socket} = TodoClient.LedgerLive.handle_info({:cache_stats, %{}}, socket)
    assert MapSet.member?(socket.assigns.open_entries, key)

    html = socket.assigns |> TodoClient.LedgerLive.render() |> Phoenix.HTML.Safe.to_iodata()
    assert html |> IO.iodata_to_binary() |> String.contains?("Coverage ledger")
    assert html |> IO.iodata_to_binary() |> String.contains?("Loaded fields:")
    assert html |> IO.iodata_to_binary() |> String.contains?("Recent query decisions")
    assert html |> IO.iodata_to_binary() |> String.contains?("cache hit")
    assert html |> IO.iodata_to_binary() |> String.contains?("From cache: Visible todo")
    assert html |> IO.iodata_to_binary() |> String.contains?("From server: Visible todo")

    assert CountingRouter.rpc_count() == rpc_count
  end

  test "keeps one entry and shows the excluded ID until it is read", %{list: list} do
    todo = server_create_todo!(%{title: "One", list_id: list.id})

    query = Ash.Query.filter(Todo, list_id == ^list.id)
    assert [_] = Ash.read!(query, actor: TodoClient.Session.actor())

    AshMultiDatalayer.forget!(Todo, %{id: todo.id})

    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
    {:ok, socket} = TodoClient.LedgerLive.mount(%{}, %{}, socket)
    entries = Enum.find(socket.assigns.resources, &(&1.label == "Todos")).entries

    assert length(entries) == 1
    assert hd(entries).filter =~ "list_id"
    assert hd(entries).filter =~ "id !="
    assert hd(entries).filter =~ todo.id

    assert [_] = Ash.read!(query, actor: TodoClient.Session.actor())
    {:noreply, socket} = TodoClient.LedgerLive.handle_event("refresh", %{}, socket)
    entries = Enum.find(socket.assigns.resources, &(&1.label == "Todos")).entries
    assert length(entries) == 1
    refute hd(entries).filter =~ "id !="
  end
end
