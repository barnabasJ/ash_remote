defmodule AshRemote.Backend.ManifestTest do
  @moduledoc """
  What `AshRemote.Server.manifest_json/1` publishes beyond Ash's stock
  serialization: relationship source/destination attributes and mirrorable
  validations (builtin modules, literal opts, mirrorable `where` conditions —
  everything else, e.g. function validations, is skipped).
  """
  use ExUnit.Case, async: true

  defp todo_resource do
    :ash_remote
    |> AshRemote.Server.manifest_json()
    |> Jason.decode!()
    |> Map.fetch!("resources")
    |> Enum.find(&(&1["module"] == "AshRemote.Backend.Todo"))
  end

  defp todo_validations, do: Map.fetch!(todo_resource(), "validations")

  test "injects source/destination attributes into relationships" do
    relationships = Map.fetch!(todo_resource(), "relationships")

    assert relationships["subtasks"]["source_attribute"] == "id"
    assert relationships["subtasks"]["destination_attribute"] == "parent_id"
    assert relationships["parent"]["source_attribute"] == "parent_id"
    assert relationships["user"]["source_attribute"] == "user_id"
  end

  test "publishes mirrorable validations, including where-guarded ones" do
    validations = todo_validations()
    by_module = Enum.group_by(validations, & &1["module"])

    assert [string_length] = by_module["Ash.Resource.Validation.StringLength"]
    assert string_length["opts"] =~ "attribute: :title"
    assert string_length["opts"] =~ "min: 3"
    assert string_length["on"] == ["create", "update"]
    assert string_length["where"] == []

    assert [match] = by_module["Ash.Resource.Validation.Match"]
    assert match["opts"] =~ "{Spark.Regex, :cache, [\"^[^!]\", []]}"

    # `where` conditions are the same {module, opts} shape as validations and
    # mirror when they pass the same test.
    assert [present] = by_module["Ash.Resource.Validation.Present"]

    assert present["where"] == [
             %{"module" => "Ash.Resource.Validation.Changing", "opts" => "[field: :title]"}
           ]
  end

  test "skips non-mirrorable validations (function validation)" do
    modules = todo_validations() |> Enum.map(& &1["module"])
    refute "Ash.Resource.Validation.Function" in modules
    assert length(modules) == 3
  end

  test "loader round-trips the published validations" do
    path = Path.join(System.tmp_dir!(), "ash_remote_validations_manifest.json")
    File.write!(path, AshRemote.Server.manifest_json(:ash_remote))

    manifest = AshRemote.Manifest.Loader.load!(path)
    todo = manifest.resources["AshRemote.Backend.Todo"]

    assert [_, _, _] = todo.validations

    string_length =
      Enum.find(todo.validations, &(&1.module == "Ash.Resource.Validation.StringLength"))

    assert string_length.opts =~ "min: 3"
    assert string_length.on == [:create, :update]

    present = Enum.find(todo.validations, &(&1.module == "Ash.Resource.Validation.Present"))

    assert [%{module: "Ash.Resource.Validation.Changing", opts: "[field: :title]"}] =
             present.where
  end
end
