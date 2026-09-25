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

  # What ProvenCoverage guarantees for an inbound change is *conservative*:
  # `handle_external_change/2` calls `AshMultiDatalayer.forget!/3`, which probes
  # the ledger with a PK-only *unknown* row — this node never performed the
  # write, so it has no trustworthy before-image — and MDL's
  # `Invalidation.should_drop?/3` treats an unknown evaluation as a drop. So
  # every entry whose filter the changed row *could* match (anything predicated
  # on a non-PK field) is dropped and the row is physically evicted; the only
  # entry guaranteed to survive is one decidable from the PK alone (a point
  # query on a *different* PK). MDL tried the precise variant and reverted it
  # (its own `forget_test.exs` covers the stale-entry survival bug it
  # reintroduces) — see the comment above
  # `AshMultiDatalayer.Orchestrator.ProvenCoverage.handle_external_change/2`.
  test "ProvenCoverage: an update notification drops the coverage the changed row matches and evicts the row" do
    foo = Ash.create!(CachedThing, %{name: "foo", status: :open})
    bar = Ash.create!(CachedThing, %{name: "bar", status: :open})

    foo_id = warm(Ash.Query.filter(CachedThing, name == "foo"))
    bar_pk_id = warm(Ash.Query.filter(CachedThing, id == ^bar.id))

    updated = %{foo | status: :done}
    notification = Notifications.build(CachedThing, :update, updated)

    assert :ok = ChangeNotifier.notify(notification)

    remaining = entry_ids()
    refute foo_id in remaining, "the name == \"foo\" entry (foo still matches) must be dropped"

    assert bar_pk_id in remaining,
           "a point query on a different PK is decidable without a before-image and must survive"

    # Physically evicted, not just un-covered: both of `CachedThing`'s layers
    # resolve to the same Ets store (see the fixture's moduledoc), so the
    # evicted row is simply gone — no refetch can bring it back here.
    assert [] = CachedThing |> Ash.Query.filter(id == ^foo.id) |> Ash.read!()
    assert [_] = CachedThing |> Ash.Query.filter(id == ^bar.id) |> Ash.read!()
  end

  test "ProvenCoverage: a create notification drops the coverage the new row now matches" do
    bar = Ash.create!(CachedThing, %{name: "bar", status: :open})

    done_id = warm(Ash.Query.filter(CachedThing, status == :done))
    bar_pk_id = warm(Ash.Query.filter(CachedThing, id == ^bar.id))

    new_row = %CachedThing{id: Ash.UUID.generate(), name: "qux", status: :done}
    notification = Notifications.build(CachedThing, :create, new_row)

    assert :ok = ChangeNotifier.notify(notification)

    remaining = entry_ids()
    refute done_id in remaining, "status == :done's \"zero rows\" claim is now false"
    assert bar_pk_id in remaining, "a point query on an unrelated PK must survive"
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
