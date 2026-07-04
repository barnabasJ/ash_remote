defmodule AshRemote.RealtimeEchoTest do
  @moduledoc """
  Echo semantics: the client's own RPC write already fires a real local
  notification; the broadcast copy is redundant on the originator. `:suppress`
  (default) drops it; `:deliver` keeps it, marked `origin: :remote`.
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

    on_exit(fn ->
      Application.delete_env(:ash_remote, :base_url)
      Application.delete_env(:ash_remote, :realtime_test_sink)
    end)

    :ok
  end

  defp start_realtime(echo) do
    name = Module.concat(__MODULE__, "Realtime_#{echo}")

    start_supervised!(
      {AshRemote.Realtime,
       name: name, resources: [ClientTodo], base_url: @socket_base, echo: echo},
      id: name
    )

    AshRemote.Realtime.listen_lifecycle(name)
    assert_receive {AshRemote.Realtime, %{type: :connected}}, 2_000
  end

  defp remote_origin?(%{changeset: %{context: %{ash_remote: %{origin: :remote}}}}), do: true
  defp remote_origin?(_), do: false

  test "echo: :suppress delivers only the local notification for the client's own write" do
    start_realtime(:suppress)

    # A CLIENT write over RPC: attaches this connection's client_id, so the
    # server's broadcast is recognizable as this client's own echo.
    Ash.create!(ClientTodo, %{title: "mine"})

    # The local notification fires (real changeset, not origin: :remote).
    assert_receive {:notification, local}, 2_000
    refute remote_origin?(local)

    # The remote echo of our own write is suppressed.
    refute_receive {:notification, %{changeset: %{context: %{ash_remote: %{origin: :remote}}}}},
                   500
  end

  test "echo: :deliver delivers both the local and the remote copy (distinct origins)" do
    start_realtime(:deliver)

    Ash.create!(ClientTodo, %{title: "mine"})

    notifications = [receive_notification(), receive_notification()]

    assert Enum.any?(notifications, &remote_origin?/1), "expected a remote-origin copy"
    assert Enum.any?(notifications, &(not remote_origin?(&1))), "expected a local copy"
  end

  defp receive_notification do
    assert_receive {:notification, notification}, 2_000
    notification
  end
end
