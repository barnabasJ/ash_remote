defmodule TodoClient.RealtimeBridge do
  @moduledoc """
  A client-side Ash notifier. `AshRemote.Realtime.Inbound` replays each
  server-side change as a local notification on the generated remote resource;
  this bridge forwards it to LiveViews over `TodoClient.PubSub` so they refetch.
  Because the server already filtered per-record, a change only arrives here if
  the connected user was allowed to see it.
  """
  use Ash.Notifier

  @topic "remote_changes"

  def topic, do: @topic

  @impl true
  def notify(notification) do
    Phoenix.PubSub.broadcast(
      TodoClient.PubSub,
      @topic,
      {:remote_change, notification.resource, notification.action.type}
    )

    :ok
  end
end
