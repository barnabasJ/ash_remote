defmodule AshRemote.MultiDatalayer do
  @moduledoc """
  Utilities for composing `ash_remote` clients with
  [`ash_multi_datalayer`](https://hexdocs.pm/ash_multi_datalayer): the inbound
  half of the two libraries' seam, plus the ordering helper client resources
  need once that inbound notifier is in play.

  `ash_remote` replicates server-side changes to a client as realtime
  notifications; `ash_multi_datalayer` (MDL) fronts the remote data layer with a
  local authority (an ETS coverage cache for the ProvenCoverage strategy, a
  local SQLite store for LocalOutbox). On their own the two don't talk: a change
  made by *another* client arrives only as a realtime notification, which the
  local authority never sees, so it silently serves a stale row. These utilities
  close that gap by forwarding realtime signals into MDL's strategy-agnostic
  inbound callbacks (`handle_external_change/2` / `handle_external_gap/2`,
  reached via `AshMultiDatalayer.DataLayer.Info.orchestrator/1`):

    * `AshRemote.MultiDatalayer.ChangeNotifier` — an `Ash.Notifier` that turns
      each per-record realtime notification into the strategy's
      `handle_external_change/2` reaction (ProvenCoverage invalidates the covered
      rows; LocalOutbox refreshes the row into the local authority).
    * `AshRemote.MultiDatalayer.LifecycleGuard` — a `GenServer` that turns a
      realtime *gap* (`:resubscribed`/`:join_denied`, where at-most-once delivery
      means writes may have been missed) into the strategy's
      `handle_external_gap/2` reaction (ProvenCoverage drops the ledger for the
      resource+tenant; LocalOutbox runs a full reconcile).

  MDL is an **optional dependency** of `ash_remote` — these utilities only make
  sense for a resource backed by `AshMultiDatalayer.DataLayer`, and compile away
  cleanly (raising a clear error only if actually invoked) in an app that pulls
  `ash_remote` without MDL. The out-of-band self-heal (`forget!/3`,
  `not_found?/1`) and per-row invalidation live in MDL's own public API
  (`AshMultiDatalayer.forget!/3`, `AshMultiDatalayer.not_found?/1`).

  ## Notifier ordering

  `Ash.Notifier.notify/1` dispatches a resource's declared `notifiers: [...]`
  with a plain synchronous, strict-declaration-order loop — no `Task`, no
  concurrency. For a client resource wired to `AshRemote.Realtime`,
  `AshRemote.MultiDatalayer.ChangeNotifier` MUST run before any UI-refresh
  notifier, or the UI could refetch before the local authority is updated and
  serve one stale read:

      notifiers: [AshRemote.MultiDatalayer.ChangeNotifier, MyApp.RealtimeBridge]

  This has to be written as a literal list, not built via a helper function call
  (`notifiers: AshRemote.MultiDatalayer.notifiers([...])`, say) — `use
  Ash.Resource` needs `data_layer:`/`notifiers:` to be compile-time literals to
  auto-include the data layer's own DSL sections (confirmed empirically: a
  resource with `data_layer: AshMultiDatalayer.DataLayer` and a `notifiers:`
  value that is a function call, not a literal list, silently loses access to the
  `multi_data_layer do ... end` section entirely). So there is no way to make the
  ordering structurally unenforceable-to-get-wrong; use `ordered?/1` in your own
  test suite instead, as a regression guard:

      test "the change notifier runs first" do
        assert AshRemote.MultiDatalayer.ordered?(MyApp.SomeRemoteResource)
      end
  """

  @doc """
  Whether `resource`'s configured notifiers list has
  `AshRemote.MultiDatalayer.ChangeNotifier` first (or has no other notifiers at
  all). Meant for a resource author's own test suite — see the moduledoc.
  """
  @spec ordered?(Ash.Resource.t()) :: boolean()
  def ordered?(resource) do
    case Ash.Resource.Info.notifiers(resource) do
      [AshRemote.MultiDatalayer.ChangeNotifier | _] -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Prepends the change notifier so it always runs before `rest`.

  Only usable where the result is a genuine runtime value (e.g. building a
  notifiers list programmatically, or in a test) — NOT as
  `notifiers: AshRemote.MultiDatalayer.notifiers([...])` inside `use
  Ash.Resource`; see the moduledoc for why that specific spot needs a literal
  list instead.
  """
  @spec notifiers([module()] | module()) :: [module()]
  def notifiers(rest \\ []),
    do: [AshRemote.MultiDatalayer.ChangeNotifier | List.wrap(rest)]
end
