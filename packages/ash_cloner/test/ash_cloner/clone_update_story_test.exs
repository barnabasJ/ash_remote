defmodule AshCloner.CloneUpdateStoryTest do
  @moduledoc """
  The package's reason to exist, end to end: a library ships real resources
  (the fixture lib), a user installs them under their own namespace, edits
  and extends them, and later updates to a new library version — gaining
  what's new without losing what they changed.
  """
  use ExUnit.Case, async: false

  import Igniter.Test

  alias AshCloner.SourceCloner

  @fixture_modules [
    AshClonerFixtures.Blog.Post,
    AshClonerFixtures.Blog.Comment,
    AshClonerFixtures.Blog.Domain
  ]

  @post_path "lib/user_app/blog/post.ex"

  defp clone(igniter, opts \\ []) do
    definitions = SourceCloner.from_modules(@fixture_modules, namespace: "UserApp.Blog")

    AshCloner.apply_definitions(
      igniter,
      definitions,
      Keyword.merge(
        [labels: [definitions: "the library's resources", upstream: "the library"]],
        opts
      )
    )
  end

  # "Version 2" of the library's Post: a new attribute and a stricter
  # validation, exactly the kind of change a library update ships.
  defp clone_v2(igniter, opts \\ []) do
    v2 =
      AshClonerFixtures.Blog.Post
      |> source!()
      |> String.replace(
        "attribute :published_at, :utc_datetime_usec, public?: true",
        "attribute :published_at, :utc_datetime_usec, public?: true\n    attribute :subtitle, :string, public?: true"
      )
      |> String.replace("min: 3", "min: 5")

    definitions =
      SourceCloner.from_sources(
        [v2, source!(AshClonerFixtures.Blog.Comment), source!(AshClonerFixtures.Blog.Domain)],
        namespace: "UserApp.Blog",
        prefix: "AshClonerFixtures.Blog"
      )

    AshCloner.apply_definitions(
      igniter,
      definitions,
      Keyword.merge(
        [labels: [definitions: "the library's resources", upstream: "the library"]],
        opts
      )
    )
  end

  defp source!(module), do: File.read!(to_string(module.module_info(:compile)[:source]))

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  defp tweak(project, path, from, to) do
    edited = String.replace(content(project, path), from, to)

    project
    |> Igniter.update_file(path, &Rewrite.Source.update(&1, :content, edited))
    |> apply_igniter!()
  end

  test "install: the library's resources land in the user's namespace" do
    igniter = test_project() |> clone()

    assert_creates(igniter, @post_path)
    assert_creates(igniter, "lib/user_app/blog/comment.ex")
    assert_creates(igniter, "lib/user_app/blog/domain.ex")

    source = content(igniter, @post_path)
    assert source =~ "defmodule UserApp.Blog.Post do"
    assert source =~ "domain: UserApp.Blog.Domain"
    # the library's helper and docs came along
    assert source =~ "def preview_length, do: 50"
  end

  test "re-running against the same library version is a no-op" do
    test_project()
    |> clone()
    |> apply_igniter!()
    |> clone()
    |> assert_unchanged()
  end

  test "update: new entities arrive, user edits survive, drift is reported" do
    # The user installs v1, renames an attribute type, and adds an action.
    project =
      test_project()
      |> clone()
      |> apply_igniter!()
      |> tweak(@post_path, "attribute(:title, :string", "attribute(:title, :ci_string")
      |> tweak(
        @post_path,
        "actions do",
        "actions do\n    read :published do\n      filter expr(not is_nil(published_at))\n    end\n"
      )

    # The library ships v2.
    igniter = clone_v2(project)

    # the v2 additions: :subtitle arrives; the changed validation is re-added
    # alongside the user's copy (validations are anonymous)
    result = igniter |> apply_igniter!() |> content(@post_path)
    assert result =~ "attribute(:subtitle, :string"
    assert result =~ "min: 5"
    assert result =~ "min: 3"

    # the user's edit and addition survive
    assert result =~ "attribute(:title, :ci_string"
    assert result =~ "read :published"

    # and the disagreements are surfaced, speaking the caller's labels
    assert_has_warning(
      igniter,
      &(&1 =~ ~r/:title differs from the library's resources/)
    )

    assert_has_warning(
      igniter,
      &(&1 =~ ~r/doesn't match any published by the library's resources/)
    )
  end

  test "update, interactively: the user adopts the library's version per entity" do
    project =
      test_project()
      |> clone()
      |> apply_igniter!()
      |> tweak(@post_path, "attribute(:title, :string", "attribute(:title, :ci_string")

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    # :title "Keep the current version?" -> no (take the library's)
    send(self(), {:mix_shell_input, :prompt, "n"})
    # the user's old validation (min: 3, now drifted): "Keep it?" -> no
    send(self(), {:mix_shell_input, :prompt, "n"})

    result =
      project
      |> clone_v2(interactive: true)
      |> apply_igniter!()
      |> content(@post_path)

    assert result =~ "attribute(:title, :string"
    refute result =~ ":ci_string"
    assert result =~ "min: 5"
    refute result =~ "min: 3"
  end
end
