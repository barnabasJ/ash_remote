defmodule AshRemote.RealtimePubSubTest do
  @moduledoc """
  Regression guard: a replicated notification carries a synthetic changeset, so
  a client resource using `Ash.Notifier.PubSub` with a `:_pkey` topic fires
  without crashing (PubSub dereferences `notification.changeset.resource`).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshRemote.Backend.TestBackend
  alias AshRemote.RealtimeClient.PubSubTodo

  @socket_base "http://127.0.0.1:4748"

  setup do
    TestBackend.reset!()
    Application.put_env(:ash_remote, :base_url, TestBackend.base_url())

    start_supervised!(
      {AshRemote.Realtime,
       name: __MODULE__.Realtime, resources: [PubSubTodo], base_url: @socket_base}
    )

    AshRemote.Realtime.listen_lifecycle(__MODULE__.Realtime)
    assert_receive {AshRemote.Realtime, %{type: :connected}}, 2_000

    on_exit(fn -> Application.delete_env(:ash_remote, :base_url) end)
    :ok
  end

  test "Ash.Notifier.PubSub :_pkey topic fires for a replicated update" do
    todo = Ash.create!(AshRemote.Backend.Todo, %{title: "PubSub", status: :pending})

    # The replicated update publishes to `pubsub_todo:updated:<pkey>`.
    Phoenix.PubSub.subscribe(AshRemote.Backend.PubSub, "pubsub_todo:updated:#{todo.id}")

    Ash.update!(todo, %{title: "PubSub!"})

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "update",
                     topic: "pubsub_todo:updated:" <> _,
                     payload: payload
                   },
                   2_000

    # payload is the reconstructed notification, carrying the decoded record
    assert payload.data.id == todo.id
    assert payload.data.title == "PubSub!"
  end
end
