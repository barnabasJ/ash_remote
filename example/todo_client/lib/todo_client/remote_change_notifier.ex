defmodule TodoClient.RemoteChangeNotifier do
  @moduledoc """
  Invalidate the online cache for peer changes. This demo delivers a client's
  own realtime echo so its separate LocalOutbox mirror can converge, but the
  online mirror already handled that write and must not invalidate twice.
  """
  use Ash.Notifier

  @impl Ash.Notifier
  def notify(notification) do
    if get_in(notification.metadata || %{}, ["ash_remote", :own_echo?]) do
      :ok
    else
      AshRemote.MultiDatalayer.ChangeNotifier.notify(notification)
    end
  end
end
