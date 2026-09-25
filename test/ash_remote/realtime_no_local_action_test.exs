defmodule AshRemote.RealtimeNoLocalActionTest do
  @moduledoc """
  Regression: a client resource with NO local action matching a replicated
  backend mutation — no same-named action, no primary action of the same
  type (`AshRemote.RealtimeClient.ReadOnlyTodo` only declares `:read`) — must
  still fire its notifiers on that mutation, not skip replication entirely.

  This is the shape of a worker-facing local cache/outbox mirroring a backend
  resource whose write actions are admin-only (never mirrored locally): the
  cache still needs to be invalidated/refreshed when an admin mutates the
  server-side row, even though the client has no local action to "replay".
  `AshMultiDatalayer.Notifiers.ExternalChange`-style notifiers only ever read
  `notification.data`/`notification.changeset.to_tenant`, never a genuinely
  resolved action — so `AshRemote.Realtime.Inbound.resolve_action/3` falls
  back to a synthetic, type-only action rather than skipping.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshRemote.Backend.TestBackend
  alias AshRemote.RealtimeClient.ReadOnlyTodo

  @socket_base "http://127.0.0.1:4748"

  setup do
    TestBackend.reset!()
    Application.put_env(:ash_remote, :base_url, TestBackend.base_url())
    Application.put_env(:ash_remote, :realtime_test_sink, self())

    {:ok, sup} =
      start_supervised(
        {AshRemote.Realtime,
         name: __MODULE__.Realtime, resources: [ReadOnlyTodo], base_url: @socket_base}
      )

    AshRemote.Realtime.listen_lifecycle(__MODULE__.Realtime)
    assert_receive {AshRemote.Realtime, %{type: :connected}}, 2_000

    on_exit(fn ->
      Application.delete_env(:ash_remote, :base_url)
      Application.delete_env(:ash_remote, :realtime_test_sink)
    end)

    %{sup: sup}
  end

  test "a server-side update replicates to a client resource with no matching local action" do
    server_todo = Ash.create!(AshRemote.Backend.Todo, %{title: "Buy milk", status: :pending})
    # The create above also replicates; drain it before asserting the update.
    assert_receive {:notification, %{action: %{type: :create}}}, 2_000

    Ash.update!(server_todo, %{title: "Buy oat milk"}, action: :update)

    assert_receive {:notification, notification}, 2_000
    assert notification.action.type == :update
    assert notification.data.id == server_todo.id
    assert notification.data.title == "Buy oat milk"
  end
end
