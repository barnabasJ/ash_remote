defmodule AshCloner.SourceClonerTest do
  use ExUnit.Case, async: true

  alias AshCloner.{Definition, SourceCloner}

  @fixture_modules [
    AshClonerFixtures.Blog.Post,
    AshClonerFixtures.Blog.Comment,
    AshClonerFixtures.Blog.Domain
  ]

  describe "from_modules/2" do
    test "finds source via module_info and re-namespaces everything" do
      definitions = SourceCloner.from_modules(@fixture_modules, namespace: "UserApp.Content")

      assert [
               %Definition{module: "UserApp.Content.Post", kind: :resource},
               %Definition{module: "UserApp.Content.Comment", kind: :resource},
               %Definition{module: "UserApp.Content.Domain", kind: :domain} = domain
             ] = definitions

      [post, comment, _domain] = definitions

      # defmodule head, `use ... domain:` option, and relationship
      # destinations are all re-namespaced
      assert post.source =~ "defmodule UserApp.Content.Post do"
      assert post.source =~ "domain: UserApp.Content.Domain"
      assert post.source =~ "has_many :comments, UserApp.Content.Comment"
      assert comment.source =~ "belongs_to :post, UserApp.Content.Post"
      refute post.source =~ "AshClonerFixtures"

      # domain resource references are renamed, in both source and resources:
      assert domain.resources == ["UserApp.Content.Post", "UserApp.Content.Comment"]
      assert domain.source =~ "resource UserApp.Content.Post"
    end

    test "non-Ash references (Ash.Resource, String, …) are untouched" do
      [post | _] = SourceCloner.from_modules(@fixture_modules, namespace: "UserApp.Content")

      assert post.source =~ "use Ash.Resource"
      assert post.source =~ "data_layer: Ash.DataLayer.Ets"
    end

    test "helper functions and comments survive verbatim" do
      [post | _] = SourceCloner.from_modules(@fixture_modules, namespace: "UserApp.Content")

      assert post.source =~ "def preview_length, do: 50"
      assert post.source =~ "# A plain helper (and this comment) that the cloner must carry over"
      assert post.source =~ ~s(A "library-authored" resource)
    end

    test "entities are keyed per section" do
      [post | _] = SourceCloner.from_modules(@fixture_modules, namespace: "UserApp.Content")

      assert Enum.map(post.entities.attributes, &elem(&1, 0)) ==
               [:id, :title, :body, :published_at]

      assert [{:comments, code}] = post.entities.relationships
      assert code == "has_many :comments, UserApp.Content.Comment"

      assert [{:preview, _}] = post.entities.calculations
      assert [{:comment_count, _}] = post.entities.aggregates

      # `defaults [:read, :destroy]` declares no named entity — only the
      # explicit action declarations are tracked
      assert Enum.map(post.entities.actions, &elem(&1, 0)) == [:create, :update]

      assert [{code, code}] = post.entities.validations
      assert code == "validate string_length(:title, min: 3)"
    end

    test "a non-Ash module clones as :verbatim" do
      [slug] = SourceCloner.from_modules([AshClonerFixtures.Blog.Slug], namespace: "UserApp")

      assert %Definition{module: "UserApp.Slug", kind: :verbatim, entities: %{}} = slug
      assert slug.source =~ "def slugify(title)"
    end

    test ":sources overrides lookup" do
      path =
        Path.join(
          System.tmp_dir!(),
          "ash_cloner_sources_override_#{System.unique_integer([:positive])}.ex"
        )

      File.write!(path, """
      defmodule AshClonerFixtures.Blog.Slug do
        def slugify(_), do: "from-the-override"
      end
      """)

      on_exit(fn -> File.rm(path) end)

      [slug] =
        SourceCloner.from_modules([AshClonerFixtures.Blog.Slug],
          namespace: "UserApp",
          sources: %{AshClonerFixtures.Blog.Slug => path}
        )

      assert slug.source =~ "from-the-override"
    end

    test "an unavailable module raises with guidance" do
      assert_raise ArgumentError, ~r/not available/, fn ->
        SourceCloner.from_modules([No.Such.Module], namespace: "UserApp")
      end
    end
  end

  describe "from_source/2" do
    test "clones every top-level defmodule, prefix inferred" do
      definitions =
        SourceCloner.from_source(
          """
          defmodule MyLib.Blog.Post do
            use Ash.Resource, domain: MyLib.Blog.Domain

            attributes do
              uuid_primary_key :id
            end
          end

          defmodule MyLib.Blog.Domain do
            use Ash.Domain

            resources do
              resource MyLib.Blog.Post
            end
          end
          """,
          namespace: "UserApp.Content"
        )

      assert [%{module: "UserApp.Content.Post"}, %{module: "UserApp.Content.Domain"}] =
               definitions
    end

    test "an explicit :prefix wins over inference" do
      [post] =
        SourceCloner.from_source(
          """
          defmodule MyLib.Blog.Post do
            use Ash.Resource, domain: MyLib.Blog.Domain

            attributes do
              uuid_primary_key :id
            end
          end
          """,
          namespace: "UserApp",
          prefix: "MyLib"
        )

      assert post.module == "UserApp.Blog.Post"
      assert post.source =~ "domain: UserApp.Blog.Domain"
    end

    test "an empty prefix nests cloned modules without touching other aliases" do
      [post] =
        SourceCloner.from_source(
          """
          defmodule Post do
            use Ash.Resource, data_layer: Ash.DataLayer.Ets

            attributes do
              uuid_primary_key :id
            end
          end
          """,
          namespace: "UserApp",
          prefix: []
        )

      assert post.module == "UserApp.Post"
      assert post.source =~ "use Ash.Resource"
      assert post.source =~ "Ash.DataLayer.Ets"
      refute post.source =~ "UserApp.Ash"
    end

    test ":otp_app rewrites the use options" do
      [post] =
        SourceCloner.from_source(
          """
          defmodule MyLib.Post do
            use Ash.Resource, otp_app: :my_lib, domain: MyLib.Domain

            attributes do
              uuid_primary_key :id
            end
          end
          """,
          namespace: "UserApp",
          prefix: "MyLib",
          otp_app: :user_app
        )

      assert post.source =~ "otp_app: :user_app"
      refute post.source =~ ":my_lib"
    end
  end
end
