defmodule AshRemote.RealtimeTest do
  @moduledoc """
  End-to-end client runtime: a real Slipstream connection to the test Phoenix
  endpoint (4748), auto-joining a topic per `realtime?` resource. A server-side
  mutation is replicated to the client as a local Ash notification with a
  reconstructed synthetic changeset.
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

    {:ok, sup} =
      start_supervised(
        {AshRemote.Realtime,
         name: __MODULE__.Realtime, resources: [ClientTodo], base_url: @socket_base}
      )

    AshRemote.Realtime.listen_lifecycle(__MODULE__.Realtime)
    assert_receive {AshRemote.Realtime, %{type: :connected}}, 2_000

    on_exit(fn ->
      Application.delete_env(:ash_remote, :base_url)
      Application.delete_env(:ash_remote, :realtime_test_sink)
    end)

    %{sup: sup}
  end

  test "a server-side create is replicated as a local notification with a synthetic changeset" do
    # A server-local write (NOT via RPC) — proves notifier-level capture.
    server_todo = Ash.create!(AshRemote.Backend.Todo, %{title: "Buy milk", status: :pending})

    assert_receive {:notification, notification}, 2_000

    # Re-emitted on the CLIENT resource, with a real local action struct.
    assert notification.resource == ClientTodo
    assert notification.action.name == :create
    assert notification.action.type == :create
    assert notification.data.id == server_todo.id
    assert notification.data.title == "Buy milk"
    # attribute types are cast on decode (enum stays an atom)
    assert notification.data.status == :pending

    # Synthetic changeset is populated (the Ash.Notifier.PubSub :_pkey/:_tenant guard).
    assert notification.changeset.resource == ClientTodo
    assert notification.changeset.action.name == :create
    assert notification.changeset.valid?
    assert notification.changeset.context.ash_remote.origin == :remote
    assert notification.changeset.attributes[:title] == "Buy milk"

    # metadata carries the ash_remote envelope
    assert notification.metadata["ash_remote"].origin == :remote
    assert is_binary(notification.metadata["ash_remote"].id)
  end

  test "a server-side update is replicated with changed attributes" do
    todo = Ash.create!(AshRemote.Backend.Todo, %{title: "Draft", status: :pending})
    assert_receive {:notification, %{action: %{type: :create}}}, 2_000

    Ash.update!(todo, %{title: "Final"})

    assert_receive {:notification, notification}, 2_000
    assert notification.action.type == :update
    assert notification.data.title == "Final"
    assert notification.changeset.attributes[:title] == "Final"
  end
end
