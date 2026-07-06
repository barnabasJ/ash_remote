defmodule TodoClient.InvalidationWiringTest do
  @moduledoc """
  Proves the actual hand-edits on the generated `TodoClient.Remote.*`
  resources are correct — not just that `ash_remote`'s own abstract fixture
  works (that's `ash_remote`'s own test suite), but that THIS app's real
  resources are wired the way the README says: the change notifier listed
  first, and a fabricated realtime notification (the same shape
  `AshRemote.Realtime.Inbound` constructs) correctly drops exactly the
  coverage it should on the real `Todo`/`TodoList` resources.
  """
  use TodoClient.Case, async: false

  alias AshMultiDatalayer.Coverage

  defp actor, do: TodoClient.Session.actor()

  defp build_notification(resource, action_name, data) do
    domain = Ash.Resource.Info.domain(resource)
    action = Ash.Resource.Info.action(resource, action_name)

    changeset = %Ash.Changeset{
      resource: resource,
      domain: domain,
      action: action,
      action_type: action.type,
      data: data,
      attributes: %{},
      tenant: nil,
      to_tenant: nil,
      context: %{ash_remote: %{origin: :remote}},
      valid?: true
    }

    %Ash.Notifier.Notification{
      resource: resource,
      domain: domain,
      action: action,
      data: data,
      changeset: changeset,
      actor: nil,
      metadata: %{}
    }
  end

  test "the change notifier is listed first on both remote resources" do
    assert AshRemote.MultiDatalayer.ordered?(Todo)
    assert AshRemote.MultiDatalayer.ordered?(TodoList)
  end

  defp warm(query) do
    before_ids = Coverage.entries(Todo, nil) |> MapSet.new(& &1.id)
    result = Ash.read!(query, actor: actor())

    entry_id =
      Coverage.entries(Todo, nil)
      |> Enum.find(&(&1.id not in before_ids))
      |> Map.fetch!(:id)

    {entry_id, result}
  end

  test "a fabricated remote update notification drops only the matching coverage", %{
    list: list,
    other_list: other_list
  } do
    server_create_todo!(%{title: "Here", list_id: list.id})
    server_create_todo!(%{title: "There", list_id: other_list.id})

    # Warm coverage through the real client resource — this also backfills
    # the row into the cache layer as a genuine %TodoClient.Remote.Todo{}.
    {list_entry_id, [here]} = warm(Ash.Query.filter(Todo, list_id == ^list.id))
    {other_entry_id, _} = warm(Ash.Query.filter(Todo, list_id == ^other_list.id))

    # This client never wrote `here` locally — it's cached purely from the
    # read above. The change notifier routes the notification through the
    # resource's ProvenCoverage orchestrator, which drops the coverage the row
    # matches and physically evicts it.
    updated = %{here | completed: true}
    notification = build_notification(Todo, :update, updated)

    assert :ok = AshRemote.MultiDatalayer.ChangeNotifier.notify(notification)

    remaining = Coverage.entries(Todo, nil) |> MapSet.new(& &1.id)
    refute list_entry_id in remaining
    assert other_entry_id in remaining
  end

  test "LifecycleGuard drops the full ledger on a fabricated :resubscribed event",
       %{list: list} do
    server_create_todo!(%{title: "Here", list_id: list.id})
    Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!(actor: actor())
    assert Coverage.entries(Todo, nil) != []

    {:ok, pid} = AshRemote.MultiDatalayer.LifecycleGuard.start_link(realtime_names: [])

    send(
      pid,
      {AshRemote.Realtime,
       %AshRemote.Realtime.Event{type: :resubscribed, resource: Todo, tenant: nil}}
    )

    :sys.get_state(pid)

    assert Coverage.entries(Todo, nil) == []
  end
end
