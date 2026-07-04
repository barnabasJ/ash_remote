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

  defp update_todo_field(manifest, name, fun) do
    key = "AshRemote.Backend.Todo"
    todo = manifest.resources[key]
    todo = %{todo | fields: Map.update!(todo.fields, name, fun)}
    %{manifest | resources: Map.put(manifest.resources, key, todo)}
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

  describe "aggregates" do
    test "a reproducible relationship aggregate becomes a NATIVE client aggregate", %{
      manifest: manifest
    } do
      source = todo_source(manifest)

      # emitted as the real thing (foldable by a caching data layer), in an
      # `aggregates do` block — not proxied as an opaque `remote(...)` calc.
      assert source =~ "aggregates do"
      assert source =~ ~r/count :comment_count, :comments do/
      refute source =~ ~s|remote("comment_count"|
    end

    test "an aggregate whose relationship didn't mirror stays a remote() proxy calc", %{
      manifest: manifest
    } do
      # Without the injected relationship (e.g. a multi-hop path or a
      # non-mirrorable filter on the server), the aggregate is not reproducible.
      manifest = update_todo_field(manifest, "comment_count", &%{&1 | relationship: nil})
      source = todo_source(manifest)

      refute source =~ ~r/count :comment_count, :comments/
      assert source =~ ~s|remote("comment_count"|
    end

    test "a mirrored aggregate filter is rendered into the native aggregate", %{
      manifest: manifest
    } do
      manifest =
        update_todo_field(
          manifest,
          "comment_count",
          &%{&1 | aggregate_filter: "not is_nil(body)"}
        )

      source = todo_source(manifest)

      assert source =~ ~r/count :comment_count, :comments do/
      assert source =~ "filter expr(not is_nil(body))"
    end
  end
end
