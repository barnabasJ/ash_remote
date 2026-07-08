defmodule AshRemote.MultiDatalayer.LifecycleGuardTest do
  @moduledoc """
  The gap reaction, both sides of the strategy seam:

    * a ProvenCoverage resource *drops its whole ledger* on a realtime gap
      (`:resubscribed`/`:join_denied`);
    * a resource on a different strategy dispatches to *that* strategy's
      `handle_external_gap/2` — proving the guard is strategy-agnostic.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshMultiDatalayer.Coverage
  alias AshRemote.MultiDatalayer.LifecycleGuard
  alias AshRemote.Realtime.Event
  alias AshRemote.Test.MultiDatalayer.Resources.{CachedThing, SpyThing}
  alias AshRemote.Test.MultiDatalayer.SpyOrchestrator

  setup do
    AshMultiDatalayer.TestSupport.reset!(CachedThing)
    :ok
  end

  defp warm(query), do: Ash.read!(query)

  # `realtime_names: []` skips `listen_lifecycle/1` registration entirely — no
  # live AshRemote.Realtime supervisor needed — since these tests drive
  # `handle_info/2` directly via `send/2`.
  defp start_guard(opts \\ [realtime_names: []]) do
    {:ok, pid} = LifecycleGuard.start_link(opts)
    pid
  end

  test "ProvenCoverage: resubscribed drops the resource+tenant's entire ledger" do
    Ash.create!(CachedThing, %{name: "foo"})
    warm(Ash.Query.filter(CachedThing, name == "foo"))
    assert Coverage.entries(CachedThing, nil) != []

    pid = start_guard()

    send(
      pid,
      {AshRemote.Realtime, %Event{type: :resubscribed, resource: CachedThing, tenant: nil}}
    )

    :sys.get_state(pid)

    assert Coverage.entries(CachedThing, nil) == []
  end

  test "ProvenCoverage: join_denied drops the ledger the same way as resubscribed" do
    Ash.create!(CachedThing, %{name: "foo"})
    warm(Ash.Query.filter(CachedThing, name == "foo"))
    assert Coverage.entries(CachedThing, nil) != []

    pid = start_guard()

    send(
      pid,
      {AshRemote.Realtime, %Event{type: :join_denied, resource: CachedThing, tenant: nil}}
    )

    :sys.get_state(pid)

    assert Coverage.entries(CachedThing, nil) == []
  end

  test "connected/disconnected are no-ops (no resource/tenant to act on)" do
    Ash.create!(CachedThing, %{name: "foo"})
    warm(Ash.Query.filter(CachedThing, name == "foo"))
    before_entries = Coverage.entries(CachedThing, nil)
    assert before_entries != []

    pid = start_guard()
    send(pid, {AshRemote.Realtime, %Event{type: :connected, resource: nil, tenant: nil}})
    send(pid, {AshRemote.Realtime, %Event{type: :disconnected, resource: nil, tenant: nil}})
    :sys.get_state(pid)

    assert Coverage.entries(CachedThing, nil) == before_entries
  end

  test "the drop is scoped to the event's own tenant — other tenants' coverage survives" do
    Coverage.ensure_table(CachedThing)
    entry_a = %{id: make_ref()}
    entry_b = %{id: make_ref()}
    Coverage.insert(CachedThing, "tenant-a", entry_a)
    Coverage.insert(CachedThing, "tenant-b", entry_b)

    pid = start_guard()

    send(
      pid,
      {AshRemote.Realtime, %Event{type: :resubscribed, resource: CachedThing, tenant: "tenant-a"}}
    )

    :sys.get_state(pid)

    assert Coverage.entries(CachedThing, "tenant-a") == []
    assert Coverage.entries(CachedThing, "tenant-b") == [entry_b]
  end

  test "an event for an unrelated resource doesn't touch this resource's ledger" do
    Ash.create!(CachedThing, %{name: "foo"})
    warm(Ash.Query.filter(CachedThing, name == "foo"))
    before_entries = Coverage.entries(CachedThing, nil)
    assert before_entries != []

    pid = start_guard()

    # SpyThing is a different resource/strategy; its gap reaction reports but
    # never touches CachedThing's ledger.
    SpyOrchestrator.watch(self())
    send(pid, {AshRemote.Realtime, %Event{type: :resubscribed, resource: SpyThing, tenant: nil}})
    :sys.get_state(pid)

    assert Coverage.entries(CachedThing, nil) == before_entries
  end

  test "strategy-agnostic: dispatches the gap to the resource's own orchestrator" do
    SpyOrchestrator.watch(self())

    pid = start_guard()
    send(pid, {AshRemote.Realtime, %Event{type: :resubscribed, resource: SpyThing, tenant: "t1"}})
    :sys.get_state(pid)

    assert_receive {:external_gap, SpyThing, "t1"}
  end

  test "listen_lifecycle/1 wiring works end-to-end via a real registry" do
    {:ok, _} = AshRemote.Realtime.start_link(resources: [], name: __MODULE__.Realtime)
    {:ok, pid} = LifecycleGuard.start_link(realtime_names: [__MODULE__.Realtime])

    Ash.create!(CachedThing, %{name: "foo"})
    warm(Ash.Query.filter(CachedThing, name == "foo"))
    assert Coverage.entries(CachedThing, nil) != []

    registry = Module.concat(__MODULE__.Realtime, Lifecycle)
    event = %Event{type: :resubscribed, resource: CachedThing, tenant: nil}

    Registry.dispatch(registry, :lifecycle, fn entries ->
      for {entry_pid, _} <- entries, do: send(entry_pid, {AshRemote.Realtime, event})
    end)

    :sys.get_state(pid)

    assert Coverage.entries(CachedThing, nil) == []
  end

  # R0 #26: landed but untested — LifecycleGuard.init/1 monitors the
  # registry process and handle_info({:DOWN, ...}) re-calls
  # listen_lifecycle/1 (== monitor_registry/1) to re-register with whatever
  # NEW registry instance the supervisor restarts in its place. Prove the
  # guard survives a registry crash+restart, not just its initial wiring.
  test "surviving a registry crash: the guard re-monitors and re-registers with the restarted registry" do
    {:ok, _} = AshRemote.Realtime.start_link(resources: [], name: __MODULE__.RealtimeRestart)
    {:ok, pid} = LifecycleGuard.start_link(realtime_names: [__MODULE__.RealtimeRestart])

    registry = Module.concat(__MODULE__.RealtimeRestart, Lifecycle)
    assert is_pid(Process.whereis(registry))

    Ash.create!(CachedThing, %{name: "foo"})
    warm(Ash.Query.filter(CachedThing, name == "foo"))
    assert Coverage.entries(CachedThing, nil) != []

    # Drive handle_info({:DOWN, ...}) directly, the same way the other tests
    # in this file drive handle_info/2 directly via send/2 rather than a
    # real process crash (a real Process.exit/2 kill risks cascading through
    # AshRemote.Realtime's own supervision tree in ways unrelated to what
    # this test is actually about). Pull the guard's real monitor ref for
    # this name out of its own state so the :DOWN message matches exactly
    # what a genuine registry crash would deliver.
    %{refs: refs_before} = :sys.get_state(pid)

    {ref, __MODULE__.RealtimeRestart} =
      Enum.find(refs_before, fn {_ref, n} -> n == __MODULE__.RealtimeRestart end)

    send(pid, {:DOWN, ref, :process, Process.whereis(registry), :killed})
    :sys.get_state(pid)

    # The guard must have dropped the old ref and established a NEW
    # monitor for the same name (monitor_registry/1's re-registration) —
    # proving it doesn't just silently lose track of this name forever.
    %{refs: refs_after} = :sys.get_state(pid)
    refute Map.has_key?(refs_after, ref)
    assert Enum.any?(refs_after, fn {_ref, n} -> n == __MODULE__.RealtimeRestart end)

    # And the guard is still live and correctly wired: a real event through
    # the (still-running) registry reaches it.
    event = %Event{type: :resubscribed, resource: CachedThing, tenant: nil}

    Registry.dispatch(registry, :lifecycle, fn entries ->
      for {entry_pid, _} <- entries, do: send(entry_pid, {AshRemote.Realtime, event})
    end)

    :sys.get_state(pid)

    assert Coverage.entries(CachedThing, nil) == []
  end
end
