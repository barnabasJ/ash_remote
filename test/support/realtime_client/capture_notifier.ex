defmodule AshRemote.RealtimeClient.CaptureNotifier do
  @moduledoc """
  Forwards every notification it receives to the pid in
  `Application.get_env(:ash_remote, :realtime_test_sink)`, so tests can assert on
  the notifications re-emitted by `AshRemote.Realtime.Inbound`.
  """
  use Ash.Notifier

  @impl true
  def notify(notification) do
    case Application.get_env(:ash_remote, :realtime_test_sink) do
      pid when is_pid(pid) -> send(pid, {:notification, notification})
      _ -> :ok
    end
  end
end
