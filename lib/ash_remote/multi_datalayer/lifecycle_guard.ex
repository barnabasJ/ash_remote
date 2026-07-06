defmodule AshRemote.MultiDatalayer.LifecycleGuard do
  @moduledoc """
  Closes the notification gap `AshRemote.Realtime` documents: notifications are
  at-most-once, so any write that happens while this client's websocket is
  disconnected produces zero notifications — nothing for
  `AshRemote.MultiDatalayer.ChangeNotifier` to react to — yet the local
  authority may now hold stale rows for that resource+tenant with no way to know
  which ones. `%AshRemote.Realtime.Event{type: :resubscribed}` is
  `AshRemote.Realtime`'s own documented "refetch now" signal for exactly this;
  `:join_denied` (e.g. a server-side authorization/tenant change) is treated the
  same way, since it also means this client can no longer trust what it
  previously cached for that resource+tenant.

  On either event this forwards to the resource's `ash_multi_datalayer` strategy
  — resolved via `AshMultiDatalayer.DataLayer.Info.orchestrator/1` — through its
  `handle_external_gap/2`, so the reaction is strategy-appropriate and this guard
  needs zero strategy knowledge:

    * **ProvenCoverage** drops the ENTIRE coverage ledger for that
      resource+tenant (a missed notification carries no row-level information to
      invalidate precisely).
    * **LocalOutbox** runs a full reconcile of the local authority against the
      source of truth for that resource+tenant.

  Same house style throughout: unknown degrades to a full-but-safe reconcile,
  never staleness; a reaction never crashes the guard.

  `:connected`/`:disconnected` are connection-wide (`resource`/`tenant` are
  always `nil` on these — see `AshRemote.Realtime.Connection`'s `emit/3`, which
  only attaches topic metadata to `:resubscribed`/`:join_denied`) and are only
  logged at `:debug`.

  ## Supervision

  Start it AFTER `{AshRemote.Realtime, ...}` — the `AshRemote.Realtime.Lifecycle`
  registry `listen_lifecycle/1` registers with is itself created as a child of
  `AshRemote.Realtime`'s own supervisor `init/1`, so it doesn't exist until that
  supervisor has started. A `Supervisor.start_link/2` call doesn't return to its
  parent until every one of its own children (the registry, then each websocket
  `Connection`) has started, so by the time `AshRemote.Realtime` itself is
  running as a sibling, the registry `listen_lifecycle/1` needs is guaranteed to
  already exist:

      children = [
        AshMultiDatalayer.Supervisor,
        {AshRemote.Realtime, otp_app: :my_app, ...},
        {AshRemote.MultiDatalayer.LifecycleGuard, realtime_names: [AshRemote.Realtime]},
        ...
      ]

  A connection could in principle finish its handshake and emit `:connected` in
  the brief window before this guard calls `listen_lifecycle/1` — harmless, since
  `:connected` is a no-op here (see below), and nowhere near enough time for a
  genuine cache-population-then-gap sequence to occur in between.

  Apps running more than one named `AshRemote.Realtime` supervisor (multiple
  base_urls under different `:name`s) must list every name in `:realtime_names` —
  `listen_lifecycle/1` registers on that name's own registry, so one guard only
  hears events for the names it's given.

  `ash_multi_datalayer` is an optional dependency: if MDL is not loaded the guard
  still starts and simply ignores gap events (there is no local authority to
  reconcile).
  """
  use GenServer

  require Logger

  alias AshRemote.Realtime.Event

  @info AshMultiDatalayer.DataLayer.Info

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    names =
      case Keyword.get(opts, :realtime_names) do
        nil -> [Keyword.get(opts, :realtime_name, AshRemote.Realtime)]
        names -> names
      end

    Enum.each(names, &AshRemote.Realtime.listen_lifecycle/1)

    {:ok, %{}}
  end

  @impl true
  def handle_info(
        {AshRemote.Realtime, %Event{type: type, resource: resource, tenant: tenant}},
        state
      )
      when type in [:resubscribed, :join_denied] and not is_nil(resource) do
    reconcile(resource, tenant, type)
    {:noreply, state}
  end

  def handle_info({AshRemote.Realtime, %Event{type: type}}, state)
      when type in [:connected, :disconnected] do
    Logger.debug("ash_remote: realtime #{type}")
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Route the gap to whatever strategy the resource declares — ProvenCoverage
  # drops the ledger, LocalOutbox reconciles. Never crashes the guard: a dropped
  # gap reaction self-heals on the next read.
  defp reconcile(resource, tenant, type) do
    if Code.ensure_loaded?(@info) do
      {orchestrator, _opts} = @info.orchestrator(resource)

      if function_exported?(orchestrator, :handle_external_gap, 2) do
        orchestrator.handle_external_gap(resource, tenant)

        Logger.info(
          "ash_remote: #{type} for #{inspect(resource)} (tenant #{inspect(tenant)}) — " <>
            "ran #{inspect(orchestrator)}.handle_external_gap/2"
        )
      end
    else
      Logger.debug(
        "ash_remote: #{type} for #{inspect(resource)} — ash_multi_datalayer not loaded, ignoring"
      )
    end
  rescue
    error ->
      Logger.warning(
        "ash_remote: gap reaction skipped for #{inspect(resource)}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )
  end
end
