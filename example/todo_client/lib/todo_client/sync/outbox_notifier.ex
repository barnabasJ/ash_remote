defmodule TodoClient.Sync.OutboxNotifier do
  @moduledoc """
  Broadcasts a lightweight "the outbox changed" tick whenever an outbox entry is
  created or transitions state (pending → synced / parked). `OfflineLive`
  subscribes and reloads, so the editing client's own sync badge settles the
  moment its flush commits — it is excluded from the server's realtime echo, so
  this local notification is its only prompt signal.

  This is an `Ash.Notifier`, invoked after the action's transaction commits — the
  idiomatic place to publish, never from a lifecycle (`before/after_action`) hook.
  """
  use Ash.Notifier

  @topic "outbox_changes"

  def topic, do: @topic

  @impl Ash.Notifier
  def notify(_notification) do
    Phoenix.PubSub.broadcast(TodoClient.PubSub, @topic, :outbox_changed)
    :ok
  end
end
