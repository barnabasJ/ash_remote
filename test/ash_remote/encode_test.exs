defmodule AshRemote.EncodeTest do
  use ExUnit.Case, async: true
  require Ash.Query
  import Ash.Expr

  alias AshRemote.Encode.{Filter, Sort}

  describe "Filter.encode/1" do
    test "nil filter → nil" do
      assert Filter.encode(nil) == nil
    end

    test "equality predicate" do
      filter = filter_of(AshRemote.Client.Todo, expr(completed == true))
      assert Filter.encode(filter) == %{"completed" => %{"eq" => true}}
    end

    test "in predicate" do
      filter = filter_of(AshRemote.Client.Todo, expr(title in ["a", "b"]))
      assert Filter.encode(filter) == %{"title" => %{"in" => ["a", "b"]}}
    end

    test "boolean and" do
      filter = filter_of(AshRemote.Client.Todo, expr(completed == true and title == "x"))
      assert %{"and" => [left, right]} = Filter.encode(filter)
      assert %{"completed" => %{"eq" => true}} = left
      assert %{"title" => %{"eq" => "x"}} = right
    end

    # --- L7-4: relationship-path filter refs keep their scoping ------------
    #
    # `AshRemote.DataLayer` declares `can?({:join, _})` false, so Ash's own
    # query builder already refuses to construct a REAL relationship-path
    # filter against a generated/hand-mirrored client resource (confirmed:
    # `Todo |> Ash.Query.do_filter(expr(user.name == "Ada"))` errors "user is
    # not filterable" before a Ref ever reaches the encoder). That's a
    # separate, correct restriction (no lateral joins) — it does not make
    # `Filter.encode/1`'s own handling of such a Ref moot: `Filter.encode/1`
    # is a plain function called on whatever `Ash.Query.Ref` it's given
    # (`remote_identity_row/3` in `data_layer.ex`, for one, builds filters via
    # `Ash.Filter.parse!/2` directly, bypassing this exact capability gate).
    # A hand-built Ref isolates the encoder's own correctness the same way
    # M7's tests isolate `Decoder.place/4` with a hand-built
    # `%Ash.Query.Calculation{}` rather than relying on a round trip that
    # cannot currently produce the input shape at all.

    test "a filter on a related resource's field is nested under the relationship, not flattened" do
      ref = related_ref(:user, :name)
      {:ok, expr} = Ash.Query.Operator.Eq.new(ref, "Ada")

      # Unfixed: `ref_name/1` returns just `:name`, dropping `relationship_path`
      # entirely — the wire filter comes out as `%{"name" => %{"eq" => "Ada"}}`,
      # which the backend would read as THIS resource's own `name` field
      # (nonexistent on Todo) instead of the related User's.
      assert Filter.encode(expr) == %{"user" => %{"name" => %{"eq" => "Ada"}}}
    end

    test "a multi-hop relationship path nests one level per segment" do
      ref = %{related_ref(:user, :name) | relationship_path: [:user, :manager]}
      {:ok, expr} = Ash.Query.Operator.Eq.new(ref, "Ada")

      assert Filter.encode(expr) == %{"user" => %{"manager" => %{"name" => %{"eq" => "Ada"}}}}
    end

    defp related_ref(relationship, field) do
      %Ash.Query.Ref{
        attribute: Ash.Resource.Info.attribute(AshRemote.Client.User, field),
        relationship_path: [relationship],
        resource: AshRemote.Client.User
      }
    end
  end

  describe "Sort.encode/1" do
    test "directions map to modifiers" do
      assert Sort.encode(nil) == nil
      assert Sort.encode([]) == nil
      assert Sort.encode(title: :asc) == ["title"]
      assert Sort.encode(title: :desc) == ["-title"]
      assert Sort.encode(title: :asc_nils_first) == ["++title"]
      assert Sort.encode(title: :desc_nils_last) == ["--title"]
      assert Sort.encode(title: :asc, completed: :desc) == ["title", "-completed"]
    end

    # --- L7-5: parameterized-calc sort keeps its arguments ------------------

    test "a parameterized calc sort preserves its arguments instead of dropping them" do
      %{sort: sort} =
        AshRemote.Client.Todo
        |> Ash.Query.sort([{:title_with_prefix, {%{prefix: "P:"}, :asc}}])

      # Unfixed: `field_name/1` pulls out only the calc's NAME (from
      # `opts[:expr]` or `calc.name`) — the caller's `prefix: "P:"` argument
      # is silently dropped, so the wire sort has nowhere to carry it and
      # the backend would evaluate the calc with its default/missing args.
      assert Sort.encode(sort) == [
               %{
                 "field" => "title_with_prefix",
                 "direction" => "asc",
                 "input" => %{"prefix" => "P:"}
               }
             ]
    end

    test "a calc with no declared arguments at all still encodes as a plain string" do
      # `title_with_prefix` always has SOME `context.arguments` once resolved
      # (its `prefix` argument has a default, filled in whether or not the
      # caller supplied it) — `is_overdue` has no arguments declared at all,
      # so its resolved `context.arguments` is genuinely `%{}`.
      %{sort: sort} =
        AshRemote.Client.Todo
        |> Ash.Query.sort(is_overdue: :desc)

      assert Sort.encode(sort) == ["-is_overdue"]
    end
  end

  defp filter_of(resource, expr) do
    resource |> Ash.Query.do_filter(expr) |> Map.fetch!(:filter)
  end
end
