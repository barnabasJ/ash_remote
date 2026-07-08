defmodule AshRemote.L8AuthorizeTest do
  @moduledoc """
  L8: the RPC server dispatch must pass `authorize?: true` explicitly on
  every server-side Ash call — `dispatch/4` (read/create/update/destroy),
  `fetch!/3` (the update/destroy primary-key fetch), and `validate_action/3`
  (`/rpc/validate`). Without it, a domain configured `authorize
  :when_requested` runs every anonymous RPC UNAUTHORIZED (Ash only enforces
  policies on such a domain when the caller opts in per-call) — policies are
  silently skipped.

  `AshRemote.Backend.WhenRequestedDomain`/`WhenRequestedThing` (test
  support) are configured exactly this way: `authorize :when_requested`,
  read allowed for any present actor, create/update/destroy allowed only
  for `role: :admin`. Registered in `config/config.exs`'s test-only
  `ash_domains` list (compile-time, alongside `Backend.Domain`/
  `SecureDomain`) — `AshRemote.Server.resolve_resource/2` reads that list
  at call time, and a runtime `Application.put_env` override was tried
  first but proved racy against the rest of the (async) suite reading the
  same global config concurrently.

  **Which tests genuinely discriminate this fix, and why** (discovered
  empirically, `Ash.Actions.Helpers.add_authorize?/3`): under
  `authorize: :when_requested`, Ash ALREADY implicitly sets
  `authorize?: true` whenever the caller's opts include an `:actor` key AT
  ALL, regardless of its value — this module's own `subject_opts/1` always
  includes `actor:` whenever `opts[:actor]` is non-nil. So an actor-present
  request was, in effect, already authorized even before this fix,
  independent of the `authorize?: true` this fix adds. The **only**
  scenario where this fix changes behavior on a `:when_requested` domain is
  the **no-actor (anonymous) request** — exactly the defect description's
  own framing ("runs anonymous RPC unauthorized"). The "no actor is
  denied" tests below are the ones confirmed (via stash) to fail on
  unfixed code. The "read-authorized but mutate-forbidden" tests (the
  pass-7-High requirement) do NOT discriminate this specific fix on this
  domain config — they pass identically with or without it, since Ash's
  own `:when_requested` + actor-present rule already turns authorization on
  for them — but they are retained anyway because they are still the
  correct, valuable end-to-end proof that the underlying policy logic
  itself (not just "is authorization on at all") behaves correctly: an
  actor that can read a row is still correctly denied at the terminal
  mutation call, not merely at the fetch.
  """
  use ExUnit.Case, async: false

  alias AshRemote.Backend.WhenRequestedThing
  alias AshRemote.Server

  @resource "AshRemote.Backend.WhenRequestedThing"
  @admin %{role: :admin}
  @non_admin %{role: :user}

  setup do
    WhenRequestedThing
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))

    :ok
  end

  defp seed! do
    WhenRequestedThing
    |> Ash.Changeset.for_create(:create, %{name: "seed"}, authorize?: false)
    |> Ash.create!()
  end

  describe "read" do
    test "no actor is denied (deny-by-default under :when_requested)" do
      response = Server.run_action(:ash_remote, %{"resource" => @resource, "action" => "read"})
      assert response["success"] == false
    end

    test "an authorized actor succeeds" do
      seed!()

      response =
        Server.run_action(:ash_remote, %{"resource" => @resource, "action" => "read"},
          actor: @non_admin
        )

      assert response["success"] == true
    end
  end

  describe "create" do
    test "no actor is denied" do
      response =
        Server.run_action(:ash_remote, %{
          "resource" => @resource,
          "action" => "create",
          "input" => %{"name" => "x"}
        })

      assert response["success"] == false
      assert WhenRequestedThing |> Ash.read!(authorize?: false) == []
    end

    test "a read-authorized but create-forbidden actor is still denied (create-policy denial, not a read/fetch artifact)" do
      response =
        Server.run_action(
          :ash_remote,
          %{"resource" => @resource, "action" => "create", "input" => %{"name" => "x"}},
          actor: @non_admin
        )

      assert response["success"] == false
      assert WhenRequestedThing |> Ash.read!(authorize?: false) == []
    end

    test "an admin actor succeeds" do
      response =
        Server.run_action(
          :ash_remote,
          %{"resource" => @resource, "action" => "create", "input" => %{"name" => "x"}},
          actor: @admin
        )

      assert response["success"] == true
      assert [%{name: "x"}] = Ash.read!(WhenRequestedThing, authorize?: false)
    end
  end

  describe "update (and its fetch-helper)" do
    test "a read-authorized but update-forbidden actor is denied on the terminal mutation, not just fetch" do
      thing = seed!()

      response =
        Server.run_action(
          :ash_remote,
          %{
            "resource" => @resource,
            "action" => "update",
            "primary_key" => %{"id" => thing.id},
            "input" => %{"name" => "changed"}
          },
          actor: @non_admin
        )

      # @non_admin CAN read (fetch!/3 succeeds) but must still be denied at
      # Ash.update!/1 itself — proving the terminal mutation call carries
      # authorize?: true, not just the fetch.
      assert response["success"] == false
      assert %{name: "seed"} = Ash.get!(WhenRequestedThing, thing.id, authorize?: false)
    end

    test "no actor is denied" do
      thing = seed!()

      response =
        Server.run_action(:ash_remote, %{
          "resource" => @resource,
          "action" => "update",
          "primary_key" => %{"id" => thing.id},
          "input" => %{"name" => "changed"}
        })

      assert response["success"] == false
      assert %{name: "seed"} = Ash.get!(WhenRequestedThing, thing.id, authorize?: false)
    end

    test "an admin actor succeeds" do
      thing = seed!()

      response =
        Server.run_action(
          :ash_remote,
          %{
            "resource" => @resource,
            "action" => "update",
            "primary_key" => %{"id" => thing.id},
            "input" => %{"name" => "changed"}
          },
          actor: @admin
        )

      assert response["success"] == true
      assert %{name: "changed"} = Ash.get!(WhenRequestedThing, thing.id, authorize?: false)
    end
  end

  describe "destroy (and its fetch-helper)" do
    test "a read-authorized but destroy-forbidden actor is denied on the terminal mutation, not just fetch" do
      thing = seed!()

      response =
        Server.run_action(
          :ash_remote,
          %{
            "resource" => @resource,
            "action" => "destroy",
            "primary_key" => %{"id" => thing.id}
          },
          actor: @non_admin
        )

      assert response["success"] == false
      assert %{name: "seed"} = Ash.get!(WhenRequestedThing, thing.id, authorize?: false)
    end

    test "an admin actor succeeds" do
      thing = seed!()

      response =
        Server.run_action(
          :ash_remote,
          %{
            "resource" => @resource,
            "action" => "destroy",
            "primary_key" => %{"id" => thing.id}
          },
          actor: @admin
        )

      assert response["success"] == true

      assert_raise Ash.Error.Invalid, fn ->
        Ash.get!(WhenRequestedThing, thing.id, authorize?: false)
      end
    end
  end

  describe "/rpc/validate" do
    # `validate_action/3` gained `authorize?: true` via the same
    # `subject_opts/1` fix (consistency with every other Ash call this
    # module makes), but this endpoint structurally CANNOT enforce
    # policies through it, and no plausible fix to `subject_opts/1` alone
    # changes that: `Ash.Changeset.for_create/4`/`Ash.Query.for_read/3`
    # never evaluate policies at construction time regardless of
    # `authorize?:` — policies run as part of the actual action pipeline
    # (`Ash.create!/1`, `Ash.read!/1`, ...), which `validate_action/3`
    # never calls (`valid?/1` only inspects `changeset.valid?`/
    # `query.valid?`, a structural/casting check). Confirmed empirically
    # below: a create-forbidden actor still validates "successfully" —
    # this is deliberately, explicitly excluded from L8's enforcement
    # scope rather than silently unaddressed.
    #
    # This is judged an acceptable, recorded exclusion because the blast
    # radius is bounded: this endpoint never runs the action or returns
    # resource data — only `{"success" => boolean, "errors" => [...]}}`
    # reflecting whether the INPUT SHAPE is structurally valid (required
    # fields present, types castable, plain validations pass). The
    # information an unauthorized caller can learn is "would this input
    # satisfy this action's shape/validations", never actual record data
    # or a real write/read. Making this endpoint policy-aware for real
    # would mean routing it through `Ash.can?/3` — a materially larger
    # change (a second authorization code path with its own semantics to
    # keep in sync with the real action pipeline) than this task's scope.
    test "a create-forbidden non-admin actor still validates (documented, deliberate exclusion)" do
      response =
        Server.validate_action(
          :ash_remote,
          %{"resource" => @resource, "action" => "create", "input" => %{"name" => "x"}},
          actor: @non_admin
        )

      assert response["success"] == true
      # No side effect either way — validate never runs the action.
      assert Ash.read!(WhenRequestedThing, authorize?: false) == []
    end

    test "a structurally invalid input is still correctly rejected" do
      response =
        Server.validate_action(:ash_remote, %{
          "resource" => @resource,
          "action" => "create",
          "input" => %{}
        })

      assert response["success"] == false
    end
  end
end
