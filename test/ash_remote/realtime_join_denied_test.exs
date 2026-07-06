defmodule AshRemote.RealtimeJoinDeniedTest do
  @moduledoc """
  R-9 (fix-plan Phase B0-5 / B2-3): a durably-denied topic (the server's
  `authorize_subscription/4` refuses the join) must not be retried on every
  reconnect — `Connection.handle_topic_close/3`'s `{:failed_to_join, _}`
  clause deliberately never rejoins, but pre-fix `handle_connect/1` still
  unconditionally re-attempts EVERY configured topic on the next reconnect,
  driving a `:join_denied` → (would-be) reconcile storm forever.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshRemote.Backend.TestBackend
  alias AshRemote.RealtimeClient.Todo, as: ClientTodo

  @socket_base "http://127.0.0.1:4748"

  setup do
    TestBackend.reset!()
    Application.put_env(:ash_remote, :base_url, TestBackend.base_url())

    on_exit(fn ->
      Application.delete_env(:ash_remote, :base_url)
      ensure_endpoint_up()
    end)

    :ok
  end

  test "a denied topic emits :join_denied once and is excluded from rejoin on reconnect" do
    start_supervised!(
      {AshRemote.Realtime,
       name: __MODULE__.Realtime,
       resources: [ClientTodo],
       base_url: @socket_base,
       connect_params: %{"deny" => true}}
    )

    AshRemote.Realtime.listen_lifecycle(__MODULE__.Realtime)
    assert_receive {AshRemote.Realtime, %{type: :join_denied}}, 2_000
    refute_receive {AshRemote.Realtime, %{type: :join_denied}}, 500

    # Force a reconnect.
    Supervisor.stop(AshRemote.Backend.Endpoint)
    assert_receive {AshRemote.Realtime, %{type: :disconnected}}, 5_000
    ensure_endpoint_up()

    # No SECOND join_denied — the denied topic is excluded from the rejoin
    # attempt entirely, so the server never gets asked again.
    refute_receive {AshRemote.Realtime, %{type: :join_denied}}, 10_000
  end

  defp ensure_endpoint_up do
    case AshRemote.Backend.Endpoint.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
