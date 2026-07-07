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

    # With no forwarded actor, the read policy filters everything out (neither
    # owner-owned nor public) — no rows leak.
    assert Ash.read!(RemoteDocument) == []
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

  # --- H1: bundled remote-calculation fetches must authenticate too ---------

  describe "H1: bundled remote-calculation fetch authentication" do
    test "an authenticated Ash.load!/3 bundled fetch carries the actor's request context" do
      alice = Ash.UUID.generate()
      doc = Ash.create!(Document, %{title: "Alice doc", owner_id: alice}, authorize?: false)

      # `:is_owner` is never selected by default — this read does NOT
      # prefetch it, so the later `Ash.load!/3` is the "bundled fetch" path.
      [loaded] =
        RemoteDocument |> Ash.Query.filter(id == ^doc.id) |> Ash.read!(context: as(alice))

      # Unfixed code sends no auth header at all regardless of what's
      # passed here — the backend's read policy (owner_id == actor(:id) or
      # public) then denies the row, and the calc value comes back nil
      # instead of the correctly-authenticated `true`.
      [with_calc] = Ash.load!([loaded], :is_owner, context: as(alice))
      assert with_calc.is_owner == true
    end

    test "explicit context headers (not just an actor token) reach the bundled fetch" do
      alice = Ash.UUID.generate()
      doc = Ash.create!(Document, %{title: "Alice doc", owner_id: alice}, authorize?: false)

      [loaded] =
        RemoteDocument |> Ash.Query.filter(id == ^doc.id) |> Ash.read!(context: as(alice))

      # No `actor:` at all — only explicit `context: %{ash_remote: %{headers: ...}}}`,
      # exactly the second auth source `request_headers/1` supports for
      # ordinary reads. A fix that only threads the actor-token path would
      # pass the test above while still dropping this one.
      [with_calc] = Ash.load!([loaded], :is_owner, context: as(alice))
      assert with_calc.is_owner == true
    end

    test "a genuinely unauthenticated bundled fetch is denied by the backend's read policy" do
      alice = Ash.UUID.generate()
      doc = Ash.create!(Document, %{title: "Alice doc", owner_id: alice}, authorize?: false)

      [loaded] =
        RemoteDocument |> Ash.Query.filter(id == ^doc.id) |> Ash.read!(context: as(alice))

      [with_calc] = Ash.load!([loaded], :is_owner)
      assert with_calc.is_owner in [nil, false]
    end

    test "different actors sharing a process do NOT reuse each other's bundled-fetch memo" do
      alice = Ash.UUID.generate()
      bob = Ash.UUID.generate()

      # `public: true` so BOTH actors can read the row at all — isolates
      # memo-key scoping from the (separate) read-policy question the other
      # tests already cover.
      doc =
        Ash.create!(Document, %{title: "Public doc", owner_id: alice, public: true},
          authorize?: false
        )

      [loaded] =
        RemoteDocument |> Ash.Query.filter(id == ^doc.id) |> Ash.read!(context: as(alice))

      # Same process, same tenant/PK/specs, DIFFERENT actors. Unfixed code's
      # memo key excludes actor — bob would get alice's cached `true`.
      [as_alice] = Ash.load!([loaded], :is_owner, context: as(alice))
      assert as_alice.is_owner == true

      [as_bob] = Ash.load!([loaded], :is_owner, context: as(bob))
      assert as_bob.is_owner == false
    end

    test "same actor with different explicit headers does NOT reuse the memo" do
      alice = Ash.UUID.generate()

      doc =
        Ash.create!(Document, %{title: "Public doc", owner_id: alice, public: true},
          authorize?: false
        )

      [loaded] =
        RemoteDocument |> Ash.Query.filter(id == ^doc.id) |> Ash.read!(context: as(alice))

      [as_alice] = Ash.load!([loaded], :is_owner, context: as(alice))
      assert as_alice.is_owner == true

      # No actor at all this time, just a different (bogus) header set — an
      # actor-only memo key would still wrongly reuse alice's cached bundle.
      [unauthenticated] =
        Ash.load!([loaded], :is_owner,
          context: %{ash_remote: %{headers: %{"x-test-actor-id" => Ash.UUID.generate()}}}
        )

      assert unauthenticated.is_owner == false
    end
  end
end
