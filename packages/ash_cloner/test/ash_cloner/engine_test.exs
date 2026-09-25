defmodule AshCloner.EngineTest do
  @moduledoc """
  The apply contract: modules that don't exist are created whole; an existing
  module only gains definition entities it's missing — user additions and
  edits are never touched, and re-applying unchanged definitions is a no-op.
  """
  use ExUnit.Case, async: false

  import Igniter.Test

  alias AshCloner.Definition

  @post_path "lib/user_app/blog/post.ex"
  @domain_path "lib/user_app/blog/domain.ex"

  @post_attributes [
    {:id, "uuid_primary_key :id"},
    {:title, "attribute :title, :string, public?: true"},
    {:body, "attribute :body, :string, public?: true"}
  ]
  @post_relationships [{:comments, "has_many :comments, UserApp.Blog.Comment"}]
  @post_validations [
    {"validate string_length(:title, min: 3)", "validate string_length(:title, min: 3)"}
  ]
  @post_calculations [{:excerpt, "calculate :excerpt, :string, expr(title)"}]
  @post_aggregates [{:comment_count, "count :comment_count, :comments"}]
  @post_actions [
    {:read, "read :read do\n  primary? true\nend"},
    {:create, "create :create do\n  accept [:title, :body]\nend"}
  ]

  defp post_definition(overrides \\ []) do
    entities = %{
      attributes: overrides[:attributes] || @post_attributes,
      relationships: overrides[:relationships] || @post_relationships,
      validations: overrides[:validations] || @post_validations,
      calculations: overrides[:calculations] || @post_calculations,
      aggregates: overrides[:aggregates] || @post_aggregates,
      actions: overrides[:actions] || @post_actions
    }

    source = """
    defmodule UserApp.Blog.Post do
      use Ash.Resource,
        domain: UserApp.Blog.Domain,
        data_layer: Ash.DataLayer.Ets

    #{section_block(:attributes, entities.attributes)}

    #{section_block(:relationships, entities.relationships)}

    #{section_block(:validations, entities.validations)}

    #{section_block(:calculations, entities.calculations)}

    #{section_block(:aggregates, entities.aggregates)}

    #{section_block(:actions, entities.actions)}
    end
    """

    Definition.new(
      module: "UserApp.Blog.Post",
      kind: :resource,
      source: source,
      entities: entities
    )
  end

  defp domain_definition(resources \\ ["UserApp.Blog.Post"]) do
    resource_lines = Enum.map_join(resources, "\n", &"    resource #{&1}")

    Definition.new(
      module: "UserApp.Blog.Domain",
      kind: :domain,
      source: """
      defmodule UserApp.Blog.Domain do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
      #{resource_lines}
        end
      end
      """,
      resources: resources
    )
  end

  defp section_block(name, entities) do
    body =
      Enum.map_join(entities, "\n", fn {_name, code} ->
        code |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))
      end)

    "  #{name} do\n#{body}\n  end"
  end

  defp apply_defs(igniter, definitions, opts \\ []) do
    AshCloner.apply_definitions(igniter, definitions, opts)
  end

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  defp tweak(project, path, from, to) do
    edited = String.replace(content(project, path), from, to)

    project
    |> Igniter.update_file(path, &Rewrite.Source.update(&1, :content, edited))
    |> apply_igniter!()
  end

  test "fresh apply creates the modules whole" do
    igniter = test_project() |> apply_defs([post_definition(), domain_definition()])

    assert_creates(igniter, @post_path)
    assert_creates(igniter, @domain_path)

    # written whole — the created file is the definition source (modulo the
    # project formatter, which parenthesizes calls)
    source = content(igniter, @post_path)

    assert AshCloner.Sections.equivalent?(
             Sourceror.parse_string!(source),
             Sourceror.parse_string!(post_definition().source)
           )
  end

  test "re-applying unchanged definitions is a no-op" do
    test_project()
    |> apply_defs([post_definition(), domain_definition()])
    |> apply_igniter!()
    |> apply_defs([post_definition(), domain_definition()])
    |> assert_unchanged()
  end

  test "missing entities are added; user edits and additions survive" do
    reduced = post_definition(attributes: List.delete_at(@post_attributes, 2))

    project = test_project() |> apply_defs([reduced]) |> apply_igniter!()
    refute content(project, @post_path) =~ "attribute(:body"

    # A user tweaks an attribute and adds their own action.
    project =
      project
      |> tweak(@post_path, "attribute(:title, :string", "attribute(:title, :ci_string")
      |> tweak(
        @post_path,
        "actions do",
        "actions do\n    read :only_mine do\n      description \"user-added\"\n    end\n"
      )

    result =
      project
      |> apply_defs([post_definition(attributes: @post_attributes)])
      |> apply_igniter!()
      |> content(@post_path)

    # the entity missing from the file is added from the definitions…
    assert result =~ "attribute(:body"
    # …while the user's tweak and addition survive (the tweak also drifts,
    # which is warned about, not touched)
    assert result =~ "attribute(:title, :ci_string"
    refute result =~ "attribute(:title, :string"
    assert result =~ "read :only_mine"
  end

  describe "drift" do
    test "is surfaced as warnings by default, changing nothing" do
      igniter =
        test_project()
        |> apply_defs([post_definition()])
        |> apply_igniter!()
        |> tweak(@post_path, "attribute(:title, :string", "attribute(:title, :ci_string")
        |> tweak(@post_path, "attributes do", "attributes do\n    attribute :nickname, :string")
        |> apply_defs([post_definition()])

      assert_has_warning(
        igniter,
        &(&1 =~ ~r/:title differs from the source definitions/)
      )

      assert_has_warning(
        igniter,
        &(&1 =~
            ~r/:nickname is not in the source definitions — user-added, or removed on upstream/)
      )

      assert_unchanged(igniter)
    end

    test "warnings speak the caller's labels" do
      igniter =
        test_project()
        |> apply_defs([post_definition()])
        |> apply_igniter!()
        |> tweak(@post_path, "attribute(:title, :string", "attribute(:title, :ci_string")
        |> apply_defs([post_definition()],
          labels: [definitions: "the manifest", upstream: "the server"]
        )

      assert_has_warning(
        igniter,
        &(&1 =~
            ~r/:title differs from the manifest \(kept as-is — rerun with --interactive to resolve\)/)
      )
    end

    test "interactive: a changed entity can be replaced with the definition version" do
      project =
        test_project()
        |> apply_defs([post_definition()])
        |> apply_igniter!()
        |> tweak(@post_path, "attribute(:title, :string", "attribute(:title, :ci_string")

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      # "Keep the current version?" -> no
      send(self(), {:mix_shell_input, :prompt, "n"})

      result =
        project
        |> apply_defs([post_definition()], interactive: true)
        |> apply_igniter!()
        |> content(@post_path)

      assert result =~ "attribute(:title, :string"
      refute result =~ ":ci_string"
    end

    test "tuple-form and sugar-form validations are equivalent — no drift" do
      project = test_project() |> apply_defs([post_definition()]) |> apply_igniter!()

      # expand the sugar into its tuple form, with shuffled orders
      project =
        tweak(
          project,
          @post_path,
          "validate(string_length(:title, min: 3))",
          "validate {Ash.Resource.Validation.StringLength, [min: 3, attribute: :title]}, on: [:update, :create]"
        )

      project |> apply_defs([post_definition()]) |> assert_unchanged()
    end

    test "an edited validation is flagged and the definition version re-added" do
      project =
        test_project()
        |> apply_defs([post_definition()])
        |> apply_igniter!()
        |> tweak(@post_path, "min: 3", "min: 5")

      igniter = apply_defs(project, [post_definition()])

      assert_has_warning(
        igniter,
        &(&1 =~ "doesn't match any published by the source definitions")
      )

      result = igniter |> apply_igniter!() |> content(@post_path)
      assert result =~ "min: 5"
      assert result =~ "min: 3"
    end

    test "interactive: extras can be kept (user-added) or removed (gone upstream)" do
      # Applied in full, plus a user-added attribute. The new definitions no
      # longer carry :excerpt — as if removed upstream.
      project =
        test_project()
        |> apply_defs([post_definition()])
        |> apply_igniter!()
        |> tweak(@post_path, "attributes do", "attributes do\n    attribute :nickname, :string")

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      # attributes are checked before calculations:
      # :nickname "Keep it?" -> yes; :excerpt "Keep it?" -> no
      send(self(), {:mix_shell_input, :prompt, "y"})
      send(self(), {:mix_shell_input, :prompt, "n"})

      result =
        project
        |> apply_defs([post_definition(calculations: [])], interactive: true)
        |> apply_igniter!()
        |> content(@post_path)

      assert result =~ ":nickname"
      refute result =~ ":excerpt"
    end

    test "a domain gains missing resource references; extras are flagged" do
      project =
        test_project()
        |> apply_defs([domain_definition()])
        |> apply_igniter!()
        |> tweak(@domain_path, "resource(UserApp.Blog.Post)", "resource(UserApp.Blog.Legacy)")

      igniter =
        apply_defs(project, [domain_definition(["UserApp.Blog.Post", "UserApp.Blog.Comment"])])

      assert_has_warning(igniter, &(&1 =~ "UserApp.Blog.Legacy is not in"))

      result = igniter |> apply_igniter!() |> content(@domain_path)
      assert result =~ "resource(UserApp.Blog.Post)"
      assert result =~ "resource(UserApp.Blog.Comment)"
      assert result =~ "resource(UserApp.Blog.Legacy)"
    end
  end

  test "verbatim modules are created whole and never reconciled" do
    verbatim =
      Definition.new(
        module: "UserApp.Blog.Priority",
        kind: :verbatim,
        source: "defmodule UserApp.Blog.Priority do\n  use Ash.Type.Enum, values: [:low]\nend\n"
      )

    igniter = test_project() |> apply_defs([verbatim])
    assert_creates(igniter, "lib/user_app/blog/priority.ex")

    # the user rewrites it entirely — re-applying neither touches nor warns
    reapplied =
      igniter
      |> apply_igniter!()
      |> tweak("lib/user_app/blog/priority.ex", "values: [:low]", "values: [:low, :high]")
      |> apply_defs([verbatim])

    assert_unchanged(reapplied)
    assert reapplied.issues == []
    assert reapplied.warnings == []
  end

  describe "placement" do
    test ":output changes the root for new files" do
      igniter =
        test_project()
        |> apply_defs([post_definition(), domain_definition()], output: "lib/generated")

      assert_creates(igniter, "lib/generated/user_app/blog/post.ex")
    end

    test ":path_for overrides placement entirely" do
      igniter =
        test_project()
        |> apply_defs([domain_definition()],
          path_for: fn module -> "lib/custom/#{Macro.underscore(module)}.exs" end
        )

      assert_creates(igniter, "lib/custom/user_app/blog/domain.exs")
    end
  end

  describe "output_path/2" do
    test "joins output root and underscored module path" do
      assert AshCloner.output_path("lib", "UserApp.Blog.Post") == "lib/user_app/blog/post.ex"
    end

    test "assert_contained! rejects a synthetic path escaping the output root" do
      # A module name can't reach an escaping path through Macro.underscore/1
      # (it never emits a literal ".."), so the containment layer is exercised
      # directly with an already-escaping path.
      assert_raise AshCloner.PathEscapeError, ~r/escapes the configured output root/, fn ->
        AshCloner.assert_contained!("lib", "lib/../../etc/passwd.ex", "Some.Module")
      end
    end
  end
end
