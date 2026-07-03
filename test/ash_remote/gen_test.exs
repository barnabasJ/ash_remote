defmodule AshRemote.GenTest do
  @moduledoc """
  Source-level assertions on `AshRemote.Gen` output. (The full
  generate → compile → behave chain is covered by `AshRemote.E2ETest`.)
  """
  use ExUnit.Case, async: true

  alias AshRemote.Manifest.Validation

  setup_all do
    path = Path.join(System.tmp_dir!(), "ash_remote_gen_validations_manifest.json")
    File.write!(path, AshRemote.Server.manifest_json(:ash_remote))
    %{manifest: AshRemote.Manifest.Loader.load!(path)}
  end

  defp todo_source(manifest) do
    manifest
    |> AshRemote.Gen.generate(namespace: "GenVal")
    |> Enum.find(&String.ends_with?(&1.module, ".Todo"))
    |> Map.fetch!(:source)
  end

  describe "validations" do
    test "the generated resource contains the mirrored validations, in sugar form", %{
      manifest: manifest
    } do
      source = todo_source(manifest)

      # rendered the way the backend author wrote them — the Builtins sugar,
      # with the default `on: [:create, :update]` omitted
      assert source =~ "validate string_length(:title, min: 3)\n"
      assert source =~ "validate match(:title, ~r/^[^!]/)\n"
      assert source =~ "validate present(:title, exactly: 1), where: [changing(:title)]\n"
      refute source =~ "Ash.Resource.Validation."
    end

    test "non-builtin modules and unsafe opts from a tampered manifest are dropped", %{
      manifest: manifest
    } do
      injected = [
        # module outside the builtin validation namespace
        %Validation{module: "System", opts: "[cmd: \"rm\"]", on: [:create]},
        # builtin module, but opts smuggle an MFA that Match would apply
        %Validation{
          module: "Ash.Resource.Validation.Match",
          opts: ~s([attribute: :title, match: {:"Elixir.System", :cmd, ["rm"]}]),
          on: [:create]
        },
        # mirrorable validation guarded by a non-mirrorable where condition
        %Validation{
          module: "Ash.Resource.Validation.Present",
          opts: "[attributes: [:status]]",
          on: [:create],
          where: [%{module: "MyApp.Sneaky", opts: "[]"}]
        }
      ]

      todo = manifest.resources["AshRemote.Backend.Todo"]
      todo = %{todo | validations: todo.validations ++ injected}

      manifest = %{
        manifest
        | resources: Map.put(manifest.resources, "AshRemote.Backend.Todo", todo)
      }

      source = todo_source(manifest)

      refute source =~ "System"
      refute source =~ "Sneaky"
      refute source =~ "present(:status)"
      # the legitimate ones are still there
      assert source =~ "validate string_length(:title, min: 3)"
    end
  end
end
