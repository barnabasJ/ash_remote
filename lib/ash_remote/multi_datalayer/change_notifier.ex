defmodule AshRemote.MultiDatalayer.ChangeNotifier do
  @moduledoc """
  An `Ash.Notifier` that turns a per-record realtime notification into the
  inbound reaction the resource's `ash_multi_datalayer` strategy prescribes.

  `AshRemote.Realtime.Inbound` replays each server-side change as a local Ash
  notification on the generated client resource. Listing this notifier on such a
  resource (which is also backed by `AshMultiDatalayer.DataLayer`) routes that
  notification through the resource's orchestrator — resolved via
  `AshMultiDatalayer.DataLayer.Info.orchestrator/1` — to its
  `handle_external_change/2`:

    * **ProvenCoverage** invalidates the covered rows (drops the matching
      coverage-ledger entries and physically evicts the row), so the next read is
      a genuine miss that refetches the fresh value.
    * **LocalOutbox** refreshes that row into the local authority (skipping a PK
      with unflushed local edits — the dirty-chain rule), so an online replica
      converges without a poll.

  Wire it onto the client resource BEFORE any UI-refresh notifier, as a literal
  list — see `AshRemote.MultiDatalayer`'s moduledoc for the ordering rule and why
  the list must be a compile-time literal:

      notifiers: [AshRemote.MultiDatalayer.ChangeNotifier, MyApp.RealtimeBridge]

  This is a thin, `ash_remote`-local name for
  `AshMultiDatalayer.Notifiers.ExternalChange` — the strategy dispatch and the
  never-crash-the-chain posture live there; this module exists so `ash_remote`
  users have a name in their own namespace and so the strategy logic (e.g.
  ProvenCoverage's before-image handling) stays entirely inside MDL.

  `ash_multi_datalayer` is an optional dependency: if the notifier is somehow
  invoked in an app without MDL loaded, it raises a clear error rather than
  failing obscurely.
  """
  use Ash.Notifier

  @external_change AshMultiDatalayer.Notifiers.ExternalChange

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{} = notification) do
    if Code.ensure_loaded?(@external_change) do
      @external_change.notify(notification)
    else
      raise """
      #{inspect(__MODULE__)} requires ash_multi_datalayer, which is not loaded.

      Add it as a dependency, or remove this notifier from the resource — it only
      applies to a resource backed by AshMultiDatalayer.DataLayer.
      """
    end
  end
end
