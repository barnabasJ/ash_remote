defmodule AshRemote.EncodeTest do
  use ExUnit.Case, async: true
  require Ash.Query
  import Ash.Expr

  alias AshRemote.Encode.{Filter, Sort}

  describe "Filter.encode/2" do
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

    test "gating raises for a disallowed operator" do
      filter = filter_of(AshRemote.Client.Todo, expr(title == "x"))

      assert_raise ArgumentError, ~r/not supported for field :title/, fn ->
        Filter.encode(filter, applicable: %{title: ["in"]})
      end
    end

    test "gating allows a permitted operator" do
      filter = filter_of(AshRemote.Client.Todo, expr(title == "x"))
      assert Filter.encode(filter, applicable: %{title: ["eq"]}) == %{"title" => %{"eq" => "x"}}
    end
  end

  describe "Sort.encode/1" do
    test "directions map to modifiers" do
      assert Sort.encode(nil) == nil
      assert Sort.encode([]) == nil
      assert Sort.encode(title: :asc) == "title"
      assert Sort.encode(title: :desc) == "-title"
      assert Sort.encode(title: :asc_nils_first) == "++title"
      assert Sort.encode(title: :desc_nils_last) == "--title"
      assert Sort.encode(title: :asc, completed: :desc) == "title,-completed"
    end
  end

  defp filter_of(resource, expr) do
    resource |> Ash.Query.do_filter(expr) |> Map.fetch!(:filter)
  end
end
