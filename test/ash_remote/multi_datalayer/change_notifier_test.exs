defmodule AshRemote.MultiDatalayer.ChangeNotifierTest do
  @moduledoc """
  The inbound per-record reaction, both sides of the strategy seam:

    * a ProvenCoverage resource excludes the changed ID from potentially
      affected coverage filters and physically evicts its old row;
    * a resource on a different strategy dispatches to *that* strategy's
      `handle_external_change/2` — proving the notifier is strategy-agnostic.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshMultiDatalayer.Coverage
  alias AshRemote.MultiDatalayer.ChangeNotifier
  alias AshRemote.Test.MultiDatalayer.Notifications
  alias AshRemote.Test.MultiDatalayer.Resources.{CachedThing, SpyThing}
  alias AshRemote.Test.MultiDatalayer.SpyOrchestrator

  setup do
    AshMultiDatalayer.TestSupport.reset!(CachedThing)
    :ok
  end

  # Reads `query`, returns the id of the ledger entry it newly records.
  defp warm(query) do
    before_ids = CachedThing |> Coverage.entries(nil) |> MapSet.new(& &1.id)
    Ash.read!(query)

    CachedThing
    |> Coverage.entries(nil)
    |> Enum.find(&(&1.id not in before_ids))
    |> Map.fetch!(:id)
  end

  # What ProvenCoverage guarantees for an inbound change is *conservative*:
  # `handle_external_change/2` calls `AshMultiDatalayer.forget!/3`, which probes
  # the ledger with a PK-only *unknown* row — this node never performed the
  # write, so it has no trustworthy before-image — and MDL's
  # `Invalidation.should_drop?/3` treats an unknown evaluation as potentially
  # affected. Such entries retain their identity but exclude this PK until
  # an authoritative read fills the hole.
  test "ProvenCoverage: an update notification narrows coverage and evicts the row" do
    foo = Ash.create!(CachedThing, %{name: "foo", status: :open})
    bar = Ash.create!(CachedThing, %{name: "bar", status: :open})

    foo_id = warm(Ash.Query.filter(CachedThing, name == "foo"))
    bar_pk_id = warm(Ash.Query.filter(CachedThing, id == ^bar.id))

    updated = %{foo | status: :done}
    notification = Notifications.build(CachedThing, :update, updated)

    assert :ok = ChangeNotifier.notify(notification)

    remaining = Coverage.entries(CachedThing, nil)
    assert MapSet.new(remaining, & &1.id) == MapSet.new([foo_id, bar_pk_id])
    assert Enum.find(remaining, &(&1.id == foo_id)).excluded_ids == [foo.id]
    assert Enum.find(remaining, &(&1.id == bar_pk_id)).excluded_ids == []

    # Physically evicted, not just un-covered: both of `CachedThing`'s layers
    # resolve to the same Ets store (see the fixture's moduledoc), so the
    # evicted row is simply gone — no refetch can bring it back here.
    assert [] = CachedThing |> Ash.Query.filter(id == ^foo.id) |> Ash.read!()
    assert [_] = CachedThing |> Ash.Query.filter(id == ^bar.id) |> Ash.read!()
  end

  test "ProvenCoverage: a create notification narrows coverage around the new row" do
    bar = Ash.create!(CachedThing, %{name: "bar", status: :open})

    done_id = warm(Ash.Query.filter(CachedThing, status == :done))
    bar_pk_id = warm(Ash.Query.filter(CachedThing, id == ^bar.id))

    new_row = %CachedThing{id: Ash.UUID.generate(), name: "qux", status: :done}
    notification = Notifications.build(CachedThing, :create, new_row)

    assert :ok = ChangeNotifier.notify(notification)

    remaining = Coverage.entries(CachedThing, nil)
    assert MapSet.new(remaining, & &1.id) == MapSet.new([done_id, bar_pk_id])
    assert Enum.find(remaining, &(&1.id == done_id)).excluded_ids == [new_row.id]
    assert Enum.find(remaining, &(&1.id == bar_pk_id)).excluded_ids == []
  end

  test "notify/1 never raises, even for a malformed notification" do
    assert :ok = ChangeNotifier.notify(%Ash.Notifier.Notification{resource: nil})
  end

  test "strategy-agnostic: dispatches to the resource's own orchestrator" do
    SpyOrchestrator.watch(self())

    row = %SpyThing{id: Ash.UUID.generate(), name: "spied"}
    notification = Notifications.build(SpyThing, :update, row)

    assert :ok = ChangeNotifier.notify(notification)

    assert_receive {:external_change, SpyThing, ^row}
  end
end
