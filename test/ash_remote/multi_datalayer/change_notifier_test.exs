defmodule AshRemote.MultiDatalayer.ChangeNotifierTest do
  @moduledoc """
  The inbound per-record reaction, both sides of the strategy seam:

    * a ProvenCoverage resource *invalidates* the covered rows on a notification
      (drops the matching coverage entries + physically evicts the row);
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

  defp entry_ids, do: CachedThing |> Coverage.entries(nil) |> MapSet.new(& &1.id)

  test "ProvenCoverage: an update notification drops coverage the changed row matches" do
    foo = Ash.create!(CachedThing, %{name: "foo", status: :open})
    Ash.create!(CachedThing, %{name: "bar", status: :open})

    foo_id = warm(Ash.Query.filter(CachedThing, name == "foo"))
    bar_id = warm(Ash.Query.filter(CachedThing, name == "bar"))

    updated = %{foo | status: :done}
    notification = Notifications.build(CachedThing, :update, updated)

    assert :ok = ChangeNotifier.notify(notification)

    remaining = entry_ids()
    refute foo_id in remaining, "the name == \"foo\" entry (foo still matches) must be dropped"
    assert bar_id in remaining, "the unrelated name == \"bar\" entry must survive"
  end

  test "ProvenCoverage: a create notification only invalidates entries the new row now matches" do
    Ash.create!(CachedThing, %{name: "bar", status: :open})

    open_id = warm(Ash.Query.filter(CachedThing, status == :open))
    done_id = warm(Ash.Query.filter(CachedThing, status == :done))

    new_row = %CachedThing{id: Ash.UUID.generate(), name: "qux", status: :done}
    notification = Notifications.build(CachedThing, :create, new_row)

    assert :ok = ChangeNotifier.notify(notification)

    remaining = entry_ids()
    assert open_id in remaining, "status == :open is untouched by a new :done row"
    refute done_id in remaining, "status == :done's \"zero rows\" claim is now false"
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
