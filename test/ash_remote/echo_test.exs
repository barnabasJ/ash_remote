defmodule AshRemote.EchoTest do
  @moduledoc """
  Echo correlation plumbing: a registered client id rides an RPC write as the
  `x-ash-remote-client-id` header, the server stamps it into the changeset
  context, and `AshRemote.Server.Notifier` echoes it back in `origin.client_id`
  on the broadcast — the hook the client subscriber uses to drop its own echoes.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshRemote.Backend.TestBackend
  alias AshRemote.Client.Todo
  alias AshRemote.Realtime.ClientId

  @topic "ash_remote:AshRemote.Backend.Todo"

  setup do
    TestBackend.reset!()

    Application.put_env(:ash_remote, :remote_config, %{
      Todo => %{base_url: TestBackend.base_url(), source: "AshRemote.Backend.Todo"}
    })

    Phoenix.PubSub.subscribe(AshRemote.Backend.PubSub, @topic)

    on_exit(fn ->
      Application.delete_env(:ash_remote, :remote_config)
      ClientId.delete(TestBackend.base_url())
    end)

    :ok
  end

  describe "ClientId registry" do
    test "register/get/delete round-trip, keyed by normalized base_url" do
      refute ClientId.get("http://example.test")
      id = ClientId.register("http://example.test/")
      assert is_binary(id)
      # trailing slash is normalized away
      assert ClientId.get("http://example.test") == id
      ClientId.delete("http://example.test")
      refute ClientId.get("http://example.test")
    end
  end

  describe "origin correlation over RPC" do
    test "a write with a registered client id echoes it back in origin.client_id" do
      id = ClientId.register(TestBackend.base_url())

      Ash.create!(Todo, %{title: "hello"})

      assert_receive %Phoenix.Socket.Broadcast{event: "notification", payload: payload}
      assert payload["origin"]["client_id"] == id
      assert payload["data"]["title"] == "hello"
    end

    test "a write with no registered client id carries a nil origin" do
      ClientId.delete(TestBackend.base_url())

      Ash.create!(Todo, %{title: "anon"})

      assert_receive %Phoenix.Socket.Broadcast{event: "notification", payload: payload}
      assert payload["origin"]["client_id"] == nil
    end
  end
end
