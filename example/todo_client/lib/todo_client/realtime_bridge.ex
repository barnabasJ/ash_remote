defmodule TodoClient.RealtimeBridge do
  @moduledoc """
  A client-side Ash notifier. `AshRemote.Realtime.Inbound` replays each
  server-side change as a local notification on the generated remote resource;
  this bridge forwards it to LiveViews over `TodoClient.PubSub` so they refetch.
  Because the server already filtered per-record, a change only arrives here if
  the connected user was allowed to see it.

  Listed after `TodoClient.RemoteChangeNotifier` so peer changes invalidate
  coverage before this bridge tells a LiveView to refetch. The online mirror
  ignores its own websocket echo; the LocalOutbox mirror still receives it.
  """
  use Ash.Notifier

  @topic "remote_changes"

  def topic, do: @topic

  @impl true
  def notify(notification) do
    own_echo? = get_in(notification.metadata || %{}, ["ash_remote", :own_echo?])

    unless own_echo? == true and
             notification.resource in [TodoClient.Remote.Todo, TodoClient.Remote.TodoList] do
      Phoenix.PubSub.broadcast(
        TodoClient.PubSub,
        @topic,
        {:remote_change, notification.resource, notification.action.type,
         notification.data && Map.get(notification.data, :id), notification.data}
      )
    end

    :ok
  end
end
