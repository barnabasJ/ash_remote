defmodule AshRemote.Manifest.LoaderTest do
  use ExUnit.Case, async: true

  alias AshRemote.Manifest
  alias AshRemote.Manifest.Loader

  @fixture "test/support/fixtures/manifest.json"

  setup do
    {:ok, manifest: Loader.load!(@fixture)}
  end

  test "loads schema version and resources", %{manifest: manifest} do
    assert manifest.schema_version == "1.0.0"

    assert Map.keys(manifest.resources) |> Enum.sort() == [
             "AshRemote.Backend.Comment",
             "AshRemote.Backend.Todo",
             "AshRemote.Backend.User"
           ]
  end

  test "normalizes Todo fields by kind", %{manifest: manifest} do
    todo = Manifest.resource(manifest, "AshRemote.Backend.Todo")
    assert todo.primary_key == ["id"]

    assert todo.fields["title"].kind == :attribute
    assert todo.fields["comment_count"].kind == :aggregate
    assert todo.fields["comment_count"].aggregate_kind == :count
    assert todo.fields["is_overdue"].kind == :calculation

    calc = todo.fields["title_with_prefix"]
    assert calc.kind == :calculation
    assert [%{name: "prefix"}] = calc.arguments
  end

  test "captures the named-type reference and its full definition", %{manifest: manifest} do
    todo = Manifest.resource(manifest, "AshRemote.Backend.Todo")
    status = todo.fields["status"].type
    assert status.kind == :type_ref
    assert status.module == "AshRemote.Backend.Todo.Status"

    enum = manifest.types["AshRemote.Backend.Todo.Status"]
    assert enum.kind == :enum
    assert enum.values == ["pending", "doing", "done"]
  end

  test "attaches actions from entrypoints", %{manifest: manifest} do
    todo = Manifest.resource(manifest, "AshRemote.Backend.Todo")
    names = todo.actions |> Enum.map(& &1.name) |> Enum.sort()
    assert "read" in names
    assert "create" in names
    assert "update" in names

    read = Enum.find(todo.actions, &(&1.name == "read"))
    assert read.type == :read
  end

  test "normalizes relationships", %{manifest: manifest} do
    todo = Manifest.resource(manifest, "AshRemote.Backend.Todo")
    assert todo.relationships["user"].type == :belongs_to
    assert todo.relationships["user"].cardinality == :one
    assert todo.relationships["comments"].cardinality == :many
  end

  test "rejects an unsupported schema version" do
    tmp = Path.join(System.tmp_dir!(), "bad_manifest.json")
    File.write!(tmp, Jason.encode!(%{"schema_version" => "2.0.0", "resources" => []}))
    assert {:error, {:unsupported_schema_version, "2.0.0"}} = Loader.load(tmp)
  end

  # B2: the loader is a pass-through for `aggregate_filter` — it neither
  # evaluates nor safety-rejects it (that decision lives in `AshRemote.Gen`,
  # the single safety gate, mirroring how `expression` is handled). A crafted
  # manifest with an arbitrary string here must still load, verbatim, as data.
  test "passes aggregate_filter through as opaque data, unevaluated and unrejected" do
    raw = File.read!(@fixture) |> Jason.decode!()

    injected = ~s|(elem(System.cmd("id", []), 0) == "root") or true|

    raw =
      update_in(
        raw,
        ["resources"],
        fn resources ->
          Enum.map(resources, fn
            %{"module" => "AshRemote.Backend.Todo"} = todo ->
              update_in(todo, ["fields", "comment_count"], fn field ->
                Map.merge(field, %{"relationship" => "comments", "aggregate_filter" => injected})
              end)

            resource ->
              resource
          end)
        end
      )

    tmp = Path.join(System.tmp_dir!(), "ash_remote_aggregate_filter_passthrough.json")
    File.write!(tmp, Jason.encode!(raw))

    manifest = Loader.load!(tmp)
    todo = Manifest.resource(manifest, "AshRemote.Backend.Todo")

    assert todo.fields["comment_count"].aggregate_filter == injected
    assert todo.fields["comment_count"].relationship == "comments"
  end
end
