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
    # A real manifest published from the reference backend, plus a reduced
    # variant with one attribute missing — regenerating with the full one
    # against a project generated from the reduced one must add it back.
    full_path = Path.join(System.tmp_dir!(), "ash_remote_gen_full_manifest.json")
    reduced_path = Path.join(System.tmp_dir!(), "ash_remote_gen_reduced_manifest.json")

    full = AshRemote.Server.manifest_json(:ash_remote)
    File.write!(full_path, full)

    reduced =
      full
      |> Jason.decode!()
      |> Map.update!("resources", fn resources ->
        Enum.map(resources, fn
          %{"module" => "AshRemote.Backend.Todo"} = res ->
            Map.update!(res, "fields", &Map.delete(&1, "due_date"))

          res ->
            res
        end)
      end)
      |> Jason.encode!()

    File.write!(reduced_path, reduced)
    %{full: full_path, reduced: reduced_path}
  end

  defp gen(igniter, manifest) do
    Igniter.compose_task(igniter, "ash_remote.gen", [
      "--manifest",
      manifest,
      "--namespace",
      "MyApp.Remote"
    ])
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
end
