defmodule AshRemote.ServerNotifierTest do
  # async: false — uses a process-global broadcast sink (Application env).
  use ExUnit.Case, async: false

  alias AshRemote.PubSubFixture.Post

  setup do
    Application.put_env(:ash_remote, :test_broadcast_sink, self())
    on_exit(fn -> Application.delete_env(:ash_remote, :test_broadcast_sink) end)

    # Wipe the ETS table between tests.
    Ash.bulk_destroy!(Post, :destroy, %{}, strategy: [:stream])
    :ok
  end

  describe "notify/1 broadcast" do
    test "a published create broadcasts a wire notification" do
      post = Ash.create!(Post, %{title: "Hello", published_on: ~D[2026-07-04]})

      assert_receive {:ash_remote_broadcast, topic, "notification", payload}

      assert topic == "ash_remote:AshRemote.PubSubFixture.Post"
      assert payload["v"] == 1
      assert payload["resource"] == "AshRemote.PubSubFixture.Post"
      assert payload["action"] == %{"name" => "create", "type" => "create"}
      assert payload["tenant"] == nil
      assert is_binary(payload["id"])
      assert is_binary(payload["occurred_at"])
      assert payload["origin"] == %{"client_id" => nil}

      # data carries public attributes (incl. the pk), not private ones.
      assert payload["data"]["id"] == post.id
      assert payload["data"]["title"] == "Hello"
      assert payload["data"]["published_on"] == ~D[2026-07-04]
      refute Map.has_key?(payload["data"], "secret")

      # changed carries the new values of public changeset attributes.
      assert payload["changed"]["title"] == "Hello"
    end

    test "a published update broadcasts changed attributes" do
      post = Ash.create!(Post, %{title: "First"})
      assert_receive {:ash_remote_broadcast, _topic, "notification", _create_payload}

      Ash.update!(post, %{title: "Second"})

      assert_receive {:ash_remote_broadcast, _topic, "notification", payload}
      assert payload["action"] == %{"name" => "update", "type" => "update"}
      assert payload["data"]["title"] == "Second"
      assert payload["changed"] == %{"title" => "Second"}
    end

    test "a no_publish'd action broadcasts nothing (gate)" do
      post = Ash.create!(Post, %{title: "Doomed"})
      assert_receive {:ash_remote_broadcast, _topic, "notification", _create}

      Ash.destroy!(post)

      refute_receive {:ash_remote_broadcast, _topic, "notification", _destroy}
    end
  end

  describe "AshRemote.Server.publications/1" do
    test "aggregates published pairs across the app's registered rpc domains" do
      # The backend domain (registered in :ash_domains) exposes these; with no
      # publish/no_publish they are all published at the Info level.
      pubs = AshRemote.Server.publications(:ash_remote)

      assert {AshRemote.Backend.Todo, :create} in pubs
      assert {AshRemote.Backend.Todo, :update} in pubs
    end
  end
end
