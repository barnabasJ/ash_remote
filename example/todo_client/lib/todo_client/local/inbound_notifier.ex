defmodule TodoClient.Local.InboundNotifier do
  @moduledoc """
  **Demo simulation of going offline.** The realtime socket in this example is not
  actually torn down when you press "Go offline" (that only pauses the outbound
  Oban queue), so without this the client would keep receiving pushes and never
  fall behind — making "catch up on reconnect" impossible to demonstrate.

  This notifier reproduces a truly disconnected client: while the resource's sync
  is paused, inbound changes are **dropped** (a real offline client's network
  simply delivers no notifications). A gap therefore accumulates, and `OfflineLive`
  closes it with `refresh(:all)` on "Go online".

  It is NOT how the library models offline — it is a stand-in for network absence.
  When online, it delegates to the strategy-agnostic
  `AshMultiDatalayer.Notifiers.ExternalChange` (refresh into local, dirty-rule
  aware), so the real inbound path is exercised unchanged.
  """
  use Ash.Notifier

  alias AshMultiDatalayer.Notifiers.ExternalChange
  alias AshMultiDatalayer.Orchestrator.LocalOutbox

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{resource: resource} = notification) do
    unless LocalOutbox.sync_paused?(resource) do
      ExternalChange.notify(notification)
    end

    :ok
  end
end
