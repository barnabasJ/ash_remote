defmodule AshRemote.AuthenticatedRpcTest do
  @moduledoc """
  Authenticated RPC over HTTP: an auth token forwarded from the Ash action
  context rides a request header; the server's auth plug turns it into an actor
  (via Ash.PlugHelpers), and AshRemote.Server.Router threads that actor into the
  action so the resource's read policy applies. Alice sees only Alice's records.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  require Ash.Query

  alias AshRemote.Backend.{Document, TestBackend}
  alias AshRemote.RealtimeClient.Document, as: RemoteDocument

  setup do
    Ash.bulk_destroy!(Document, :destroy, %{}, authorize?: false, strategy: [:stream])
    Application.put_env(:ash_remote, :base_url, TestBackend.base_url())
    on_exit(fn -> Application.delete_env(:ash_remote, :base_url) end)
    :ok
  end

  defp as(actor_id), do: %{ash_remote: %{headers: %{"x-test-actor-id" => actor_id}}}

  test "the forwarded actor scopes RPC reads by the resource's read policy" do
    alice = Ash.UUID.generate()
    bob = Ash.UUID.generate()

    Ash.create!(Document, %{title: "Alice doc", owner_id: alice}, authorize?: false)
    Ash.create!(Document, %{title: "Bob doc", owner_id: bob}, authorize?: false)

    # Reading as Alice returns only Alice's document.
    assert RemoteDocument |> Ash.read!(context: as(alice)) |> Enum.map(& &1.title) == [
             "Alice doc"
           ]

    # Reading as Bob returns only Bob's.
    assert RemoteDocument |> Ash.read!(context: as(bob)) |> Enum.map(& &1.title) == ["Bob doc"]

    # With no forwarded actor, the server's read policy denies access.
    assert_raise Ash.Error.Forbidden, fn -> Ash.read!(RemoteDocument) end
  end

  test "a token in the actor's metadata is auto-forwarded as a Bearer token" do
    alice = Ash.UUID.generate()
    Ash.create!(Document, %{title: "Alice doc", owner_id: alice}, authorize?: false)
    Ash.create!(Document, %{title: "Bob doc", owner_id: Ash.UUID.generate()}, authorize?: false)

    # An actor carrying a token in metadata — exactly how ash_authentication
    # returns a signed-in user. No manual header threading.
    actor =
      AshRemote.Backend.User
      |> struct(id: Ash.UUID.generate())
      |> Ash.Resource.put_metadata(:token, alice)

    assert RemoteDocument |> Ash.read!(actor: actor) |> Enum.map(& &1.title) == ["Alice doc"]
  end

  test "the forwarded actor authorizes RPC updates (get + policy)" do
    alice = Ash.UUID.generate()
    doc = Ash.create!(Document, %{title: "Owned", owner_id: alice}, authorize?: false)

    # Alice can fetch + update her own document over RPC.
    updated =
      RemoteDocument
      |> Ash.get!(doc.id, context: as(alice))
      |> Ash.Changeset.for_update(:update, %{title: "Owned v2"}, context: as(alice))
      |> Ash.update!()

    assert updated.title == "Owned v2"
  end
end
