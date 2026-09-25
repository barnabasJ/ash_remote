defmodule AshCloner.SectionsTest do
  use ExUnit.Case, async: true

  alias AshCloner.Sections

  test "section vocabulary covers the reconciled sections" do
    assert Keyword.keys(Sections.section_calls()) ==
             [:attributes, :relationships, :calculations, :aggregates, :actions]

    assert Sections.section_calls()[:aggregates] == Sections.aggregate_calls()
  end

  test "enter_section/statements walk a resource body" do
    zipper =
      """
      attributes do
        attribute :title, :string
        attribute :body, :string
      end
      """
      |> Sourceror.parse_string!()
      |> Sourceror.Zipper.zip()

    assert {:ok, inner} = Sections.enter_section(zipper, :attributes)
    assert [first, _second] = Sections.statements(inner)
    assert Sections.entity_name(first) == :title
  end

  test "enter_section misses an absent section" do
    zipper =
      "attributes do\n  attribute :title, :string\nend"
      |> Sourceror.parse_string!()
      |> Sourceror.Zipper.zip()

    assert :error = Sections.enter_section(zipper, :calculations)
  end

  test "statements of a single-statement block" do
    zipper =
      "attributes do\n  attribute :title, :string\nend"
      |> Sourceror.parse_string!()
      |> Sourceror.Zipper.zip()

    {:ok, inner} = Sections.enter_section(zipper, :attributes)
    assert [stmt] = Sections.statements(inner)
    assert Sections.entity_name(stmt) == :title
  end

  test "entity_name handles block-wrapped atoms and non-entities" do
    assert Sections.entity_name({:attribute, [], [{:__block__, [], [:title]}, :string]}) ==
             :title

    assert Sections.entity_name({:attribute, [], [{:var, [], nil}]}) == nil
    assert Sections.entity_name(:not_a_call) == nil
  end

  test "equivalent?/2 ignores formatting metadata" do
    left = Sourceror.parse_string!("attribute :title, :string, public?: true")
    right = Sourceror.parse_string!("attribute :title,\n  :string,\n  public?: true")
    changed = Sourceror.parse_string!("attribute :title, :string, public?: false")

    assert Sections.equivalent?(left, right)
    refute Sections.equivalent?(left, changed)
  end
end
