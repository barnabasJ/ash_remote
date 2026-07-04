defmodule AshRemote.RealtimeAuthnTest do
  @moduledoc """
  End-to-end authentication: a token supplied via `connect_params` rides the
  socket connect query string, the host socket's `connect/3` turns it into an
  actor (the ash_authentication integration point), and per-record authorization
  then filters the replicated stream — the subscriber only sees its own records.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshRemote.Backend.{Document, TestBackend}
  alias AshRemote.RealtimeClient.Document, as: ClientDocument

  @socket_base "http://127.0.0.1:4748"

  setup do
    TestBackend.reset!()
    Ash.bulk_destroy!(Document, :destroy, %{}, authorize?: false, strategy: [:stream])
    Application.put_env(:ash_remote, :base_url, TestBackend.base_url())
    Application.put_env(:ash_remote, :realtime_test_sink, self())

    on_exit(fn ->
      Application.delete_env(:ash_remote, :base_url)
      Application.delete_env(:ash_remote, :realtime_test_sink)
    end)

    :ok
  end

  test "connect_params establish the actor, and only readable records replicate" do
    alice = Ash.UUID.generate()
    bob = Ash.UUID.generate()

    # "actor_id" stands in for a real auth token verified in RemoteSocket.connect/3.
    start_supervised!(
      {AshRemote.Realtime,
       name: __MODULE__.Realtime,
       resources: [ClientDocument],
       base_url: @socket_base,
       connect_params: %{"actor_id" => alice}}
    )

    AshRemote.Realtime.listen_lifecycle(__MODULE__.Realtime)
    assert_receive {AshRemote.Realtime, %{type: :connected}}, 2_000

    # Alice's own document replicates to her.
    Ash.create!(Document, %{title: "Alice doc", owner_id: alice}, authorize?: false)
    assert_receive {:notification, notification}, 2_000
    assert notification.resource == ClientDocument
    assert notification.data.title == "Alice doc"

    # Bob's document does NOT (Alice's actor can't read it).
    Ash.create!(Document, %{title: "Bob doc", owner_id: bob}, authorize?: false)
    refute_receive {:notification, %{data: %{title: "Bob doc"}}}, 500
  end
end
