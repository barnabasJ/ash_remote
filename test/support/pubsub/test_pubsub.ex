defmodule AshRemote.PubSubFixture.TestPubSub do
  @moduledoc """
  A minimal stand-in for a `Phoenix.Endpoint` used to capture the notifier's
  broadcasts without pulling Phoenix. `broadcast/3` forwards to the pid stored in
  `Application.get_env(:ash_remote, :test_broadcast_sink)`. Tests using it run
  `async: false` and register their own pid.
  """
  def broadcast(topic, event, payload) do
    case Application.get_env(:ash_remote, :test_broadcast_sink) do
      pid when is_pid(pid) -> send(pid, {:ash_remote_broadcast, topic, event, payload})
      _ -> :ok
    end

    :ok
  end
end
