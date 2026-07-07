defmodule AshRemote.DataLayerTest do
  @moduledoc "M2 walking skeleton: the hand-written mirror round-trips CRUD + loads over RPC."
  use ExUnit.Case, async: false
  @moduletag :integration

  require Ash.Query
  import Ash.Expr

  alias AshRemote.Backend.TestBackend
  alias AshRemote.Client.{Comment, Todo, User}

  setup do
    TestBackend.reset!()

    Application.put_env(:ash_remote, :remote_config, %{
      User => %{base_url: TestBackend.base_url(), source: "AshRemote.Backend.User"},
      Todo => %{base_url: TestBackend.base_url(), source: "AshRemote.Backend.Todo"},
      Comment => %{base_url: TestBackend.base_url(), source: "AshRemote.Backend.Comment"}
    })

    on_exit(fn -> Application.delete_env(:ash_remote, :remote_config) end)
    :ok
  end

  defp seed do
    user = Ash.create!(User, %{name: "Ada", email: "ada@example.com"})
    todo = Ash.create!(Todo, %{title: "Write code", status: :doing, user_id: user.id})
    _c = Ash.create!(Comment, %{body: "nice", todo_id: todo.id, user_id: user.id})
    %{user: user, todo: todo}
  end

  test "create returns a decoded struct" do
    user = Ash.create!(User, %{name: "Grace", email: "grace@example.com"})
    assert %User{name: "Grace"} = user
    assert is_binary(user.id)
  end

  test "read returns decoded structs" do
    seed()
    assert [%Todo{title: "Write code", status: :doing}] = Ash.read!(Todo)
  end

  test "filter is pushed to the backend" do
    %{todo: todo} = seed()
    Ash.create!(Todo, %{title: "Other", user_id: nil})

    results = Todo |> Ash.Query.filter(id == ^todo.id) |> Ash.read!()
    assert [%Todo{id: id}] = results
    assert id == todo.id
  end

  test "sort is pushed to the backend" do
    seed()
    Ash.create!(Todo, %{title: "Aaa", user_id: nil})

    titles = Todo |> Ash.Query.sort(title: :asc) |> Ash.read!() |> Enum.map(& &1.title)
    assert titles == ["Aaa", "Write code"]
  end

  test "limit is pushed to the backend" do
    seed()
    Ash.create!(Todo, %{title: "Two", user_id: nil})
    assert [_one] = Todo |> Ash.Query.limit(1) |> Ash.read!()
  end

  test "loads aggregate, calculation (with + without args), and relationship in one read" do
    %{todo: todo} = seed()

    loaded =
      Todo
      |> Ash.Query.filter(id == ^todo.id)
      |> Ash.Query.load([
        :comment_count,
        :is_overdue,
        {:title_with_prefix, %{prefix: "TODO: "}},
        :user
      ])
      |> Ash.read_one!()

    assert loaded.comment_count == 1
    assert loaded.is_overdue == false
    # NB: the backend's :string calc argument trims trailing whitespace.
    assert loaded.title_with_prefix == "TODO:Write code"
    assert %User{name: "Ada"} = loaded.user
  end

  test "update round-trips" do
    %{todo: todo} = seed()
    updated = Ash.update!(todo, %{title: "Write more code"})
    assert updated.title == "Write more code"
    assert Ash.get!(Todo, todo.id).title == "Write more code"
  end

  test "update toggles a boolean attribute over the wire" do
    %{todo: todo} = seed()
    completed = Ash.update!(todo, %{completed: true})
    assert completed.completed == true
    assert Ash.get!(Todo, todo.id).completed == true
  end

  test "destroy round-trips" do
    %{todo: todo} = seed()
    assert :ok = Ash.destroy!(todo)
    assert [] == Todo |> Ash.Query.filter(id == ^todo.id) |> Ash.read!()
  end

  # Regression: the LocalOutbox flush destroys through
  # `AshMultiDatalayer.Backfill.destroy_record/4`, which hands the data layer an
  # ACTION-LESS changeset (`data` carries the row, `action` is nil) — the same
  # shape `upsert/3` already tolerates. `destroy/2` used to deref
  # `changeset.action.name` and crash with BadMapError, so every offline destroy
  # stayed pending forever. It must resolve the primary destroy action instead.
  test "destroy tolerates an action-less changeset (the LocalOutbox flush shape)" do
    %{todo: todo} = seed()

    changeset =
      Todo
      |> Ash.Changeset.new()
      |> Map.merge(%{data: todo, domain: Ash.Resource.Info.domain(Todo)})

    assert nil == changeset.action
    assert :ok = AshRemote.DataLayer.destroy(Todo, changeset)
    assert [] == Todo |> Ash.Query.filter(id == ^todo.id) |> Ash.read!()
  end

  test "get by primary key (read + pk filter)" do
    %{todo: todo} = seed()
    assert %Todo{id: id} = Ash.get!(Todo, todo.id)
    assert id == todo.id
  end

  # User's backend read has no pagination — Ash.get/2's internal `limit: 2`
  # must land as a plain query limit, not a page option, on such actions.
  test "get and limit work against a backend read without pagination" do
    %{user: user} = seed()
    assert %User{name: "Ada"} = Ash.get!(User, user.id)

    Ash.create!(User, %{name: "Grace", email: "grace@example.com"})
    assert [_only_one] = User |> Ash.Query.limit(1) |> Ash.read!()
  end

  # --- H2: non-PK upsert identity + accept-list truncation ------------------

  describe "H2: non-PK upsert identity" do
    test "resolves the existing row by a non-PK identity, not a PK-based miss" do
      existing = Ash.create!(User, %{name: "Ada", email: "ada@example.com"})

      upserted =
        User
        |> Ash.Changeset.for_create(:upsert_by_email, %{
          name: "Ada Updated",
          email: "ada@example.com"
        })
        |> Ash.create!()

      assert upserted.id == existing.id
      assert upserted.name == "Ada Updated"
    end

    test "the upsert-resolved update addresses the found row's actual PK, not one rebuilt from changeset attributes" do
      existing = Ash.create!(User, %{name: "Ada", email: "ada@example.com"})
      wrong_id = Ash.UUID.generate()

      # Unfixed: `put_write_action(:update)` rebuilds `data`'s PK from
      # `Ash.Changeset.get_attribute(changeset, :id)` — here a bogus id the
      # identity lookup never resolved to — targeting the wrong row instead
      # of the one the non-PK identity actually found.
      upserted =
        User
        |> Ash.Changeset.for_create(:upsert_by_email, %{
          name: "Ada v2",
          email: "ada@example.com"
        })
        |> Ash.Changeset.force_change_attribute(:id, wrong_id)
        |> Ash.create!()

      assert upserted.id == existing.id
      assert Ash.get!(User, existing.id).name == "Ada v2"
    end

    test "a replicated (upsert-resolved) update converges fields outside the primary update action's accept" do
      Ash.create!(User, %{name: "Ada", email: "ada@example.com"})

      # `:update`'s accept is `[:email]` only — `:name` is not accepted by
      # it. The upsert-resolved update path must still converge `:name`
      # since this is a replicated write, not a direct call to the narrow
      # `:update` action.
      upserted =
        User
        |> Ash.Changeset.for_create(:upsert_by_email, %{
          name: "Ada v2",
          email: "ada@example.com"
        })
        |> Ash.create!()

      assert upserted.name == "Ada v2"
    end

    test "an ordinary action-driven update still respects its own accept list" do
      existing = Ash.create!(User, %{name: "Ada", email: "ada@example.com"})

      # `force_change_attribute/3` bypasses Ash's own input-validation
      # rejection (unlike passing `name:` through `for_update`'s params,
      # which Ash itself refuses outright) — this isolates what THIS data
      # layer's `input/1`/`accepted_keys/1` does with it: a genuine
      # action-driven update (no `ash_remote_replicated_write?` context)
      # must still filter it out via the action's own `accept` list.
      updated =
        existing
        |> Ash.Changeset.for_update(:update, %{email: "ada2@example.com"})
        |> Ash.Changeset.force_change_attribute(:name, "Should Not Apply")
        |> Ash.update!()

      assert updated.email == "ada2@example.com"
      assert updated.name == "Ada"
    end
  end

  # --- M7: query calculations/aggregates decoded uncast ---------------------

  describe "M7: query-plan calculation/aggregate targets are cast to their Ash type" do
    # Unit-level (not an RPC round-trip): `place/4` is where the bug lives,
    # and exercising it directly with a well-formed %Ash.Query.Calculation{}/
    # %Ash.Query.Aggregate{} (the shape add_calculation/add_aggregate
    # receive from Ash core, `type`/`constraints` already resolved) isolates
    # the fix from ash_remote's ad-hoc-query-time-calc RPC support (which
    # turned out not to reliably resolve `.type` for every construction
    # path — a separate, pre-existing concern outside M7's scope).
    alias AshRemote.Decoder

    defp calc_target(name, type, opts \\ []) do
      {to_string(name),
       {:calculation,
        %Ash.Query.Calculation{
          name: name,
          type: type,
          constraints: opts[:constraints] || [],
          load: opts[:load]
        }}}
    end

    defp agg_target(name, type, opts \\ []) do
      {to_string(name),
       {:aggregate,
        %Ash.Query.Aggregate{
          name: name,
          type: type,
          constraints: opts[:constraints] || [],
          load: opts[:load]
        }}}
    end

    test "a calculation NOT aliased via load (the calculations map) is cast" do
      {wire_key, _target} = plan_entry = calc_target(:due_date_probe, :date)
      map = %{wire_key => "2026-08-01"}

      record = Decoder.decode_record(map, Todo, [plan_entry])

      # Unfixed: place/4's default :calculation clause Map.puts the raw
      # wire value (an ISO8601 string) straight into `calculations`.
      assert record.calculations[:due_date_probe] == ~D[2026-08-01]
    end

    test "a calculation aliased via load decodes onto the field" do
      {wire_key, _target} = plan_entry = calc_target(:deadline_echo, :date, load: :deadline_echo)
      map = %{wire_key => "2026-08-02"}

      record = Decoder.decode_record(map, Todo, [plan_entry])

      # Unfixed: place/4's load-aliased :calculation clause Map.puts the
      # raw wire value directly as the field — a plain string.
      assert record.deadline_echo == ~D[2026-08-02]
    end

    test "an aggregate NOT aliased via load (the aggregates map) is cast" do
      {wire_key, _target} = plan_entry = agg_target(:avg_rating_probe, :decimal)
      map = %{wire_key => 4.5}

      record = Decoder.decode_record(map, Todo, [plan_entry])

      # Unfixed: place/4's default :aggregate clause Map.puts the raw wire
      # value straight into `aggregates` — a float, not %Decimal{}.
      assert %Decimal{} = record.aggregates[:avg_rating_probe]
      assert Decimal.equal?(record.aggregates[:avg_rating_probe], Decimal.new("4.5"))
    end

    test "an aggregate aliased via load decodes onto the field" do
      {wire_key, _target} =
        plan_entry = agg_target(:avg_comment_rating, :decimal, load: :avg_comment_rating)

      map = %{wire_key => 3.5}

      record = Decoder.decode_record(map, Todo, [plan_entry])

      # Unfixed: place/4's load-aliased :aggregate clause Map.puts the raw
      # wire value directly as the field — a plain float.
      assert %Decimal{} = record.avg_comment_rating
      assert Decimal.equal?(record.avg_comment_rating, Decimal.new("3.5"))
    end

    test "nil and uncastable wire values pass through safely (no raise)" do
      {calc_key, _} = calc_entry = calc_target(:due_date_probe, :date)
      {agg_key, _} = agg_entry = agg_target(:avg_rating_probe, :decimal)
      map = %{calc_key => nil, agg_key => "not-a-number"}

      record = Decoder.decode_record(map, Todo, [calc_entry, agg_entry])

      assert record.calculations[:due_date_probe] == nil
      # An uncastable value falls back to the raw wire value, never raises.
      assert record.aggregates[:avg_rating_probe] == "not-a-number"
    end
  end
end
