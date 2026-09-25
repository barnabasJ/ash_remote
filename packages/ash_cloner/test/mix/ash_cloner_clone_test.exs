defmodule Mix.Tasks.AshCloner.CloneTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  @modules "AshClonerFixtures.Blog.Post,AshClonerFixtures.Blog.Comment,AshClonerFixtures.Blog.Domain"

  defp clone(igniter, extra_args \\ []) do
    Igniter.compose_task(
      igniter,
      "ash_cloner.clone",
      ["--modules", @modules, "--namespace", "UserApp.Blog"] ++ extra_args
    )
  end

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  test "clones the modules into the namespace" do
    igniter = test_project() |> clone()

    assert_creates(igniter, "lib/user_app/blog/post.ex")
    assert_creates(igniter, "lib/user_app/blog/comment.ex")
    assert_creates(igniter, "lib/user_app/blog/domain.ex")

    assert content(igniter, "lib/user_app/blog/post.ex") =~ "defmodule UserApp.Blog.Post do"
  end

  test "re-running is a no-op" do
    test_project()
    |> clone()
    |> apply_igniter!()
    |> clone()
    |> assert_unchanged()
  end

  test "--output places the clones elsewhere" do
    igniter = test_project() |> clone(["--output", "lib/cloned"])

    assert_creates(igniter, "lib/cloned/user_app/blog/post.ex")
  end

  test "--otp-app only rewrites an existing otp_app option, never invents one" do
    # (The rewrite itself is covered in AshCloner.SourceClonerTest — the
    # fixture modules don't carry `otp_app:`, so here the flag must be a
    # no-op rather than a spurious insertion.)
    igniter = clone(test_project(), ["--otp-app", "user_app"])

    refute content(igniter, "lib/user_app/blog/domain.ex") =~ "otp_app"
    assert_creates(igniter, "lib/user_app/blog/domain.ex")
  end

  test "the required options are enforced" do
    assert_raise Mix.Error, ~r/--modules is required/, fn ->
      Igniter.compose_task(test_project(), "ash_cloner.clone", ["--namespace", "UserApp"])
    end

    assert_raise Mix.Error, ~r/--namespace is required/, fn ->
      Igniter.compose_task(test_project(), "ash_cloner.clone", ["--modules", @modules])
    end
  end

  test "dry-run semantics: changes are computed on the igniter, nothing touches disk" do
    # `apply_definitions/3` never writes files itself — everything is staged
    # on the igniter, so Igniter's --dry-run/--check flags work for any task
    # built on it. The staged creation is visible…
    igniter = test_project() |> clone()
    assert_creates(igniter, "lib/user_app/blog/post.ex")

    # …while the filesystem was never involved.
    refute File.exists?("lib/user_app/blog/post.ex")

    # Same for drift warnings on a later run: staged as igniter warnings,
    # not printed-and-forgotten side effects.
    project = igniter |> apply_igniter!()

    edited =
      String.replace(
        content(project, "lib/user_app/blog/post.ex"),
        "attribute(:title, :string",
        "attribute(:title, :ci_string"
      )

    rerun =
      project
      |> Igniter.update_file(
        "lib/user_app/blog/post.ex",
        &Rewrite.Source.update(&1, :content, edited)
      )
      |> apply_igniter!()
      |> clone()

    assert_has_warning(rerun, &(&1 =~ ~r/:title differs from the library's resources/))
    refute File.exists?("lib/user_app/blog/post.ex")
  end
end
