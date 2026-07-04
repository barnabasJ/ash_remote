defmodule AshRemote.RealtimeAuthzTest do
  @moduledoc """
  Per-record subscription authorization: a subscriber only receives broadcasts
  for records its actor is allowed to read. `Document` is readable only by its
  owner, so Alice's subscription sees changes to her documents but never Bob's.
  """
  use ExUnit.Case, async: true
  import Phoenix.ChannelTest

  @endpoint AshRemote.Backend.Endpoint
  @topic "ash_remote:AshRemote.Backend.Document"

  alias AshRemote.Backend.Document

  setup do
    Ash.bulk_destroy!(Document, :destroy, %{}, authorize?: false, strategy: [:stream])
    :ok
  end

  test "a subscriber receives notifications only for records its actor can read" do
    alice = Ash.UUID.generate()
    bob = Ash.UUID.generate()

    doc_a = Ash.create!(Document, %{title: "Alice's", owner_id: alice}, authorize?: false)
    doc_b = Ash.create!(Document, %{title: "Bob's", owner_id: bob}, authorize?: false)

    # Alice connects and subscribes to the Document topic.
    {:ok, socket} = connect(AshRemote.Backend.RemoteSocket, %{"actor_id" => alice})
    {:ok, _reply, _socket} = subscribe_and_join(socket, @topic, %{})

    # A change to Alice's own document is delivered...
    Ash.update!(doc_a, %{title: "Alice's v2"}, authorize?: false)
    assert_push("notification", %{"data" => %{"title" => "Alice's v2", "owner_id" => ^alice}})

    # ...but a change to Bob's document is filtered out (Alice can't read it).
    Ash.update!(doc_b, %{title: "Bob's v2"}, authorize?: false)
    refute_push("notification", %{"data" => %{"title" => "Bob's v2"}})
  end

  test "a subscriber with no actor sees nothing for a policy-protected resource" do
    owner = Ash.UUID.generate()
    doc = Ash.create!(Document, %{title: "Secret", owner_id: owner}, authorize?: false)

    # Connect without an actor_id — actor is nil.
    {:ok, socket} = connect(AshRemote.Backend.RemoteSocket, %{})
    {:ok, _reply, _socket} = subscribe_and_join(socket, @topic, %{})

    Ash.update!(doc, %{title: "Secret v2"}, authorize?: false)
    refute_push("notification", %{"data" => %{"title" => "Secret v2"}})
  end

  test "a public record's destroy is delivered (in-memory eval, no data-layer re-read)" do
    other = Ash.UUID.generate()
    bob = Ash.UUID.generate()

    public_doc =
      Ash.create!(Document, %{title: "Shared", owner_id: other, public: true}, authorize?: false)

    private_doc =
      Ash.create!(Document, %{title: "Private", owner_id: other}, authorize?: false)

    # Bob doesn't own either, but the first is public.
    {:ok, socket} = connect(AshRemote.Backend.RemoteSocket, %{"actor_id" => bob})
    {:ok, _reply, _socket} = subscribe_and_join(socket, @topic, %{})

    # Destroying the public doc reaches Bob — even though the row is now gone, the
    # `public == true` branch resolves from the wire record with no query.
    Ash.destroy!(public_doc, authorize?: false)

    assert_push("notification", %{
      "action" => %{"type" => "destroy"},
      "data" => %{"title" => "Shared"}
    })

    # Destroying the private doc does not.
    Ash.destroy!(private_doc, authorize?: false)
    refute_push("notification", %{"data" => %{"title" => "Private"}})
  end
end
