defmodule Mix.Tasks.AshRemote.GenTest do
  @moduledoc """
  The regeneration contract: modules that don't exist are created whole; an
  existing module only gains manifest entities it's missing — user additions
  and edits are never touched, and an unchanged manifest is a no-op.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import Igniter.Test

  setup_all do
    # A real manifest published from the reference backend, plus reduced
    # variants: one missing an attribute (regen with the full manifest must add
    # it back), one missing a loadable field (its stub becomes drift: "removed
    # on the server").
    full_path = Path.join(System.tmp_dir!(), "ash_remote_gen_full_manifest.json")
    reduced_path = Path.join(System.tmp_dir!(), "ash_remote_gen_reduced_manifest.json")
    no_calc_path = Path.join(System.tmp_dir!(), "ash_remote_gen_no_calc_manifest.json")

    full = AshRemote.Server.manifest_json(:ash_remote)
    File.write!(full_path, full)

    drop_todo_field = fn json, field ->
      json
      |> Jason.decode!()
      |> Map.update!("resources", fn resources ->
        Enum.map(resources, fn
          %{"module" => "AshRemote.Backend.Todo"} = res ->
            Map.update!(res, "fields", &Map.delete(&1, field))

          res ->
            res
        end)
      end)
      |> Jason.encode!()
    end

    File.write!(reduced_path, drop_todo_field.(full, "due_date"))
    File.write!(no_calc_path, drop_todo_field.(full, "comment_count"))
    %{full: full_path, reduced: reduced_path, no_calc: no_calc_path}
  end

  defp gen(igniter, manifest, extra_args \\ []) do
    Igniter.compose_task(
      igniter,
      "ash_remote.gen",
      ["--manifest", manifest, "--namespace", "MyApp.Remote"] ++ extra_args
    )
  end

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  @todo_path "lib/my_app/remote/todo.ex"

  test "fresh generation creates the modules", %{full: full} do
    igniter = test_project() |> gen(full)

    assert_creates(igniter, @todo_path)
    assert_creates(igniter, "lib/my_app/remote/user.ex")
    assert_creates(igniter, "lib/my_app/remote/domain.ex")
  end

  test "regeneration adds missing entities and preserves user code", %{
    full: full,
    reduced: reduced
  } do
    project = test_project() |> gen(reduced) |> apply_igniter!()

    original = content(project, @todo_path)
    refute original =~ ":due_date"

    # A user tweaks a generated attribute and adds their own action.
    edited =
      original
      |> String.replace("attribute(:title, :string", "attribute(:title, :ci_string")
      |> String.replace(
        "actions do",
        "actions do\n    read :only_mine do\n      description \"user-added\"\n    end\n"
      )

    assert edited != original

    project =
      project
      |> Igniter.update_file(@todo_path, &Rewrite.Source.update(&1, :content, edited))
      |> apply_igniter!()

    result = project |> gen(full) |> apply_igniter!() |> content(@todo_path)

    # the entity missing from the file is added from the manifest…
    assert result =~ ":due_date"
    # …while the user's tweak and addition survive
    assert result =~ "attribute(:title, :ci_string"
    refute result =~ "attribute(:title, :string"
    assert result =~ "read :only_mine"
  end

  test "regeneration with an unchanged manifest is a no-op", %{full: full} do
    test_project()
    |> gen(full)
    |> apply_igniter!()
    |> gen(full)
    |> assert_unchanged()
  end

  describe "drift" do
    defp tweak(project, path, from, to) do
      edited = String.replace(content(project, path), from, to)

      project
      |> Igniter.update_file(path, &Rewrite.Source.update(&1, :content, edited))
      |> apply_igniter!()
    end

    test "is surfaced as warnings by default, changing nothing", %{full: full} do
      igniter =
        test_project()
        |> gen(full)
        |> apply_igniter!()
        |> tweak(@todo_path, "attribute(:title, :string", "attribute(:title, :ci_string")
        |> tweak(@todo_path, "attributes do", "attributes do\n    attribute(:nickname, :string)")
        |> gen(full)

      assert_has_warning(igniter, &(&1 =~ ~r/:title differs from the manifest/))
      assert_has_warning(igniter, &(&1 =~ ~r/:nickname is not in the manifest/))
      assert_unchanged(igniter)
    end

    test "interactive: a changed entity can be replaced with the manifest version", %{full: full} do
      project =
        test_project()
        |> gen(full)
        |> apply_igniter!()
        |> tweak(@todo_path, "attribute(:title, :string", "attribute(:title, :ci_string")

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      # "Keep the current version?" -> no
      send(self(), {:mix_shell_input, :prompt, "n"})

      result =
        project
        |> gen(full, ["--interactive"])
        |> apply_igniter!()
        |> content(@todo_path)

      assert result =~ "attribute(:title, :string"
      refute result =~ ":ci_string"
    end

    test "tuple-form and sugar-form validations are equivalent — no drift", %{full: full} do
      project = test_project() |> gen(full) |> apply_igniter!()

      # expand the generated sugar into its tuple form, with shuffled orders
      project =
        tweak(
          project,
          @todo_path,
          "validate string_length(:title, min: 3)",
          "validate {Ash.Resource.Validation.StringLength, [min: 3, attribute: :title]}, on: [:update, :create]"
        )

      project |> gen(full) |> assert_unchanged()
    end

    test "an edited validation is flagged and the manifest version re-added", %{full: full} do
      project =
        test_project()
        |> gen(full)
        |> apply_igniter!()
        |> tweak(@todo_path, "min: 3", "min: 5")

      igniter = gen(project, full)

      assert_has_warning(igniter, &(&1 =~ "doesn't match any published by the manifest"))

      result = igniter |> apply_igniter!() |> content(@todo_path)
      assert result =~ "min: 5"
      assert result =~ "min: 3"
    end

    test "interactive: an edited validation can be dropped for the manifest version", %{
      full: full
    } do
      project =
        test_project()
        |> gen(full)
        |> apply_igniter!()
        |> tweak(@todo_path, "min: 3", "min: 5")

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      # the edited validation: "Keep it?" -> no
      send(self(), {:mix_shell_input, :prompt, "n"})

      result =
        project
        |> gen(full, ["--interactive"])
        |> apply_igniter!()
        |> content(@todo_path)

      assert result =~ "min: 3"
      refute result =~ "min: 5"
    end

    test "interactive: extras can be kept (user-added) or removed (gone from the server)", %{
      full: full,
      no_calc: no_calc
    } do
      # Generated from the full manifest, plus a user-added attribute. The new
      # manifest no longer has :comment_count — as if removed on the server.
      project =
        test_project()
        |> gen(full)
        |> apply_igniter!()
        |> tweak(@todo_path, "attributes do", "attributes do\n    attribute(:nickname, :string)")

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      # attributes are checked before calculations:
      # :nickname "Keep it?" -> yes; :comment_count "Keep it?" -> no
      send(self(), {:mix_shell_input, :prompt, "y"})
      send(self(), {:mix_shell_input, :prompt, "n"})

      result =
        project
        |> gen(no_calc, ["--interactive"])
        |> apply_igniter!()
        |> content(@todo_path)

      assert result =~ ":nickname"
      refute result =~ ":comment_count"
    end
  end
end
