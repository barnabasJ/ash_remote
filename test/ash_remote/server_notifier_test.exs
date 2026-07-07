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

    test "an atomic update's payload is JSON-safe (no Ash expressions leak into changed)" do
      # Post has a validation, so the update is atomic and changeset.attributes
      # holds Ash expressions — changed must still carry the final plain value.
      post = Ash.create!(Post, %{title: "Draft"})
      assert_receive {:ash_remote_broadcast, _topic, "notification", _create}

      Ash.update!(post, %{title: "Published"})

      assert_receive {:ash_remote_broadcast, _topic, "notification", payload}
      assert payload["changed"] == %{"title" => "Published"}
      # The whole payload must be encodable — this is what the channel push does.
      assert {:ok, _json} = Jason.encode(payload)
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

  # --- M8: changeset-less multitenant broadcasts must not go unjoinable ------

  describe "M8: a changeset-less notification on a multitenant resource" do
    alias AshRemote.PubSubFixture.{AttrTenantThing, CtxTenantThing}

    setup do
      Ash.bulk_destroy!(AttrTenantThing, :destroy, %{}, strategy: [:stream], tenant: "acme")
      Ash.bulk_destroy!(CtxTenantThing, :destroy, %{}, strategy: [:stream], tenant: "acme")
      :ok
    end

    test "derives the tenant from the record for attribute-strategy multitenancy" do
      thing =
        AttrTenantThing
        |> Ash.Changeset.for_create(:create, %{org_id: "acme", title: "hi"}, tenant: "acme")
        |> Ash.create!()

      # The record's own create fires a normal (changeset-attached)
      # notification first — drain it before the changeset-less one below.
      assert_receive {:ash_remote_broadcast, _topic, "notification", _create}

      notification = %Ash.Notifier.Notification{
        resource: AttrTenantThing,
        domain: AshRemote.PubSubFixture.PubDomain,
        action: %{name: :update, type: :update},
        data: thing,
        changeset: nil
      }

      assert :ok = AshRemote.Server.Notifier.notify(notification)

      # Unfixed: `notification.changeset && ...` yields tenant: nil, so this
      # publishes to the untenanted topic instead — no multitenant
      # subscriber (joined on the tenant-scoped topic) ever hears it.
      assert_receive {:ash_remote_broadcast, topic, "notification", payload}
      assert topic == "ash_remote:AshRemote.PubSubFixture.AttrTenantThing:acme"
      assert payload["tenant"] == "acme"
    end

    test "context-strategy: never publishes to the unjoinable untenanted topic, and emits a concrete signal" do
      thing =
        CtxTenantThing
        |> Ash.Changeset.for_create(:create, %{title: "hi"}, tenant: "acme")
        |> Ash.create!()

      assert_receive {:ash_remote_broadcast, _topic, "notification", _create}

      test_pid = self()

      :telemetry.attach(
        "m8-test-handler",
        [:ash_remote, :server, :notifier, :unresolvable_tenant],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:unresolvable_tenant, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("m8-test-handler") end)

      notification = %Ash.Notifier.Notification{
        resource: CtxTenantThing,
        domain: AshRemote.PubSubFixture.PubDomain,
        action: %{name: :update, type: :update},
        data: thing,
        changeset: nil
      }

      assert :ok = AshRemote.Server.Notifier.notify(notification)

      # Unfixed: this DOES publish, to "ash_remote:...CtxTenantThing" (no
      # tenant segment) — a topic no context-multitenant subscriber (joined
      # on "...CtxTenantThing:acme") ever hears. The fix's failure mode
      # must be "no delivery AND no reconcile signal", not merely
      # "delivered nothing" — assert BOTH halves.
      refute_receive {:ash_remote_broadcast, _topic, "notification", _payload}
      assert_receive {:unresolvable_tenant, %{count: 1}, %{resource: CtxTenantThing}}
    end
  end

  describe "M8: non-multitenant resources are unaffected" do
    test "a changeset-less notification still publishes to the untenanted topic" do
      post = Ash.create!(Post, %{title: "plain"})
      assert_receive {:ash_remote_broadcast, _topic, "notification", _create}

      notification = %Ash.Notifier.Notification{
        resource: Post,
        domain: AshRemote.PubSubFixture.PubDomain,
        action: %{name: :update, type: :update},
        data: post,
        changeset: nil
      }

      assert :ok = AshRemote.Server.Notifier.notify(notification)

      assert_receive {:ash_remote_broadcast, topic, "notification", payload}
      assert topic == "ash_remote:AshRemote.PubSubFixture.Post"
      assert payload["tenant"] == nil
    end
  end
end
