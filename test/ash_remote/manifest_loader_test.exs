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

  # L6 item 5: `@known_atoms` must name every aggregate kind
  # `AshRemote.Gen`'s `aggregate_block/2` can render, or
  # `String.to_existing_atom/1` decoding a legitimate manifest's
  # `aggregate_kind` only succeeds by the R-8-described accident of some
  # *other* module having already loaded that atom first.
  describe "aggregate_kind vocabulary (L6 item 5)" do
    test "known_atoms/0 names every supported aggregate kind" do
      known = Loader.known_atoms()

      for kind <- [:count, :sum, :avg, :min, :max, :first, :list, :exists, :custom] do
        assert kind in known, "#{inspect(kind)} missing from Loader.known_atoms/0"
      end
    end

    # A direct ExUnit assertion here can pass "by accident" regardless of the
    # fix: as soon as anything in the same VM/test run references
    # `AshRemote.Gen`'s own `@aggregate_kinds` literal (e.g. `GenTest` running
    # earlier in the suite), `:avg`/`:custom` become known process-wide and
    # `String.to_existing_atom/1` stops discriminating. A genuinely fresh OS
    # process has no such accidental preload — confirmed empirically: a bare
    # `elixir -e` process with *nothing* but core Elixir loaded already fails
    # `String.to_existing_atom("avg")` and `String.to_existing_atom("custom")`
    # (verified while building this fix), while the other seven kinds happen
    # to already be Erlang/Elixir-builtin atoms. This spawns a real
    # subprocess reusing only the compiled `_build` artifacts (no app start,
    # so `AshRemote.Gen` is never loaded) to prove the loader's own
    # `@known_atoms` — not accidental preloading elsewhere — is what makes
    # decoding `"avg"`/`"custom"` succeed.
    test "decoding aggregate_kind: \"avg\" succeeds in a fresh VM that has never loaded AshRemote.Gen" do
      build_path = Mix.Project.build_path()
      ebin_globs = Path.wildcard(Path.join(build_path, "lib/*/ebin"))

      script = """
      Enum.each(#{inspect(ebin_globs)}, &Code.prepend_path/1)
      # Only load the loader's own module tree — never AshRemote.Gen, whose
      # `@aggregate_kinds` literal would otherwise smuggle these atoms in.
      {:ok, _} = Application.ensure_all_started(:jason)
      Code.ensure_loaded!(AshRemote.Manifest.Loader)

      json =
        Jason.encode!(%{
          "schema_version" => "1.0.0",
          "resources" => [
            %{
              "module" => "Fresh.Vm.Todo",
              "fields" => %{
                "comment_count" => %{
                  "kind" => "aggregate",
                  "aggregate_kind" => "avg",
                  "type" => %{"kind" => "decimal"}
                }
              }
            }
          ]
        })

      path = Path.join(System.tmp_dir!(), "ash_remote_l6_fresh_vm_manifest.json")
      File.write!(path, json)

      manifest = AshRemote.Manifest.Loader.load!(path)
      field = manifest.resources["Fresh.Vm.Todo"].fields["comment_count"]
      IO.puts("AGGREGATE_KIND=" <> Atom.to_string(field.aggregate_kind))
      """

      script_path = Path.join(System.tmp_dir!(), "ash_remote_l6_fresh_vm_check.exs")
      File.write!(script_path, script)

      {output, exit_code} =
        System.cmd("elixir", [script_path], stderr_to_stdout: true, cd: File.cwd!())

      assert exit_code == 0, "fresh-VM subprocess failed: #{output}"
      assert output =~ "AGGREGATE_KIND=avg"
    end
  end
end
