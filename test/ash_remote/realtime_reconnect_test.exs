defmodule AshRemote.RealtimeReconnectTest do
  @moduledoc """
  Reconnect recovery: when the endpoint drops and returns, the client emits
  `:disconnected` then `:resubscribed` (the documented "refetch now" signal) and
  notifications flow again.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshRemote.Backend.TestBackend
  alias AshRemote.RealtimeClient.Todo, as: ClientTodo

  @socket_base "http://127.0.0.1:4748"

  setup do
    TestBackend.reset!()
    Application.put_env(:ash_remote, :base_url, TestBackend.base_url())
    Application.put_env(:ash_remote, :realtime_test_sink, self())

    start_supervised!(
      {AshRemote.Realtime,
       name: __MODULE__.Realtime, resources: [ClientTodo], base_url: @socket_base}
    )

    AshRemote.Realtime.listen_lifecycle(__MODULE__.Realtime)
    assert_receive {AshRemote.Realtime, %{type: :connected}}, 2_000

    on_exit(fn ->
      Application.delete_env(:ash_remote, :base_url)
      Application.delete_env(:ash_remote, :realtime_test_sink)
      ensure_endpoint_up()
    end)

    :ok
  end

  test "the client recovers after the endpoint drops and returns" do
    # Drop the endpoint.
    Supervisor.stop(AshRemote.Backend.Endpoint)
    assert_receive {AshRemote.Realtime, %{type: :disconnected}}, 5_000

    # Bring it back — the client reconnects on backoff and rejoins.
    ensure_endpoint_up()
    assert_receive {AshRemote.Realtime, %{type: :resubscribed}}, 15_000

    # Notifications flow again.
    Ash.create!(AshRemote.Backend.Todo, %{title: "after reconnect", status: :pending})
    assert_receive {:notification, notification}, 5_000
    assert notification.data.title == "after reconnect"
  end

  defp ensure_endpoint_up do
    case AshRemote.Backend.Endpoint.start_link() do
      # Unlink so the shared endpoint survives this ephemeral test process and
      # stays up for the rest of the suite.
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
