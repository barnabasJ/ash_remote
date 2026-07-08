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

  # Renames a field's manifest KEY (the identifier `AshRemote.Gen` actually
  # splices as `:#{name}` — see `fields_of_kind/2`, which pairs on the map
  # key, not `field.name`), keeping the struct's `name` in sync.
  defp rename_todo_field(manifest, old_name, new_name) do
    key = "AshRemote.Backend.Todo"
    todo = manifest.resources[key]
    {field, fields} = Map.pop!(todo.fields, old_name)
    todo = %{todo | fields: Map.put(fields, new_name, %{field | name: new_name})}
    %{manifest | resources: Map.put(manifest.resources, key, todo)}
  end

  defp update_todo_relationship(manifest, name, fun) do
    key = "AshRemote.Backend.Todo"
    todo = manifest.resources[key]
    todo = %{todo | relationships: Map.update!(todo.relationships, name, fun)}
    %{manifest | resources: Map.put(manifest.resources, key, todo)}
  end

  # Same rename-the-key concern as `rename_todo_field/3`, for relationships.
  defp rename_todo_relationship(manifest, old_name, new_name) do
    key = "AshRemote.Backend.Todo"
    todo = manifest.resources[key]
    {rel, rels} = Map.pop!(todo.relationships, old_name)
    todo = %{todo | relationships: Map.put(rels, new_name, %{rel | name: new_name})}
    %{manifest | resources: Map.put(manifest.resources, key, todo)}
  end

  defp rename_todo_action(manifest, old_name, new_name) do
    key = "AshRemote.Backend.Todo"
    todo = manifest.resources[key]

    actions =
      Enum.map(todo.actions, fn
        %{name: ^old_name} = action -> %{action | name: new_name}
        action -> action
      end)

    todo = %{todo | actions: actions}
    %{manifest | resources: Map.put(manifest.resources, key, todo)}
  end

  # Both the manifest's resources-map KEY and the resource's own `.module`
  # field must move together — `client_module/2` reads `.module`, but
  # `Manifest.resources` is keyed by that same string.
  defp rename_todo_module(manifest, new_module) do
    key = "AshRemote.Backend.Todo"
    todo = %{manifest.resources[key] | module: new_module}
    resources = manifest.resources |> Map.delete(key) |> Map.put(new_module, todo)
    %{manifest | resources: resources}
  end

  defp set_status_enum_values(manifest, values) do
    key = "AshRemote.Backend.Todo.Status"
    type = manifest.types[key]
    %{manifest | types: Map.put(manifest.types, key, %{type | values: values})}
  end

  # L6 item 3: a calculation argument's `allow_nil?: true` was hardcoded
  # regardless of what the manifest actually says. `title_with_prefix`'s
  # `:prefix` argument is a real, already-published example of the bug — the
  # backend resource (test/support/backend/todo.ex) declares it
  # `allow_nil?(false)`, so this needs no synthetic tampering.
  # L6 item 4: the FK attribute a `belongs_to` relationship excludes from the
  # `attributes do` block (see `belongs_to_fks/1` — this exclusion was itself
  # dead code until this fix, per its own doc comment) must still carry its
  # real type/nullability, via `attribute_type:`/`allow_nil?:` on the
  # `belongs_to` line, rather than silently falling back to Ash's
  # `:uuid`/`allow_nil?: true` default.
  describe "belongs_to FK type/nullability (L6 item 4)" do
    test "user_id is excluded from attributes do and carried on belongs_to :user instead", %{
      manifest: manifest
    } do
      source = todo_source(manifest)

      refute source =~ "attribute :user_id"
      assert source =~ ~r/belongs_to :user, GenVal\.User,[^\n]*attribute_type: :uuid/
    end

    test "a non-nullable, non-uuid FK column's real type/nullability is preserved", %{
      manifest: manifest
    } do
      manifest =
        update_todo_field(manifest, "user_id", &%{&1 | type: %{&1.type | kind: :integer}})

      manifest = update_todo_field(manifest, "user_id", &%{&1 | allow_nil?: false})

      source = todo_source(manifest)

      refute source =~ "attribute :user_id"
      assert source =~ "attribute_type: :integer, allow_nil?: false"
    end

    test "a manifest that doesn't publish the FK as its own field falls back to Ash's default, not a crash",
         %{manifest: manifest} do
      key = "AshRemote.Backend.Todo"

      todo = %{
        manifest.resources[key]
        | fields: Map.delete(manifest.resources[key].fields, "user_id")
      }

      manifest = %{manifest | resources: Map.put(manifest.resources, key, todo)}

      source = todo_source(manifest)
      [user_line] = Regex.run(~r/belongs_to :user,[^\n]*/, source)

      assert user_line =~
               "belongs_to :user, GenVal.User, public?: true, attribute_writable?: true"

      refute user_line =~ "attribute_type"
    end
  end

  describe "calculation argument nullability (L6 item 3)" do
    test "an argument the backend requires (allow_nil? false) is rendered as such, not hardcoded true",
         %{manifest: manifest} do
      source = todo_source(manifest)

      assert source =~ "argument :prefix, :string, allow_nil?: false"
      refute source =~ "argument :prefix, :string, allow_nil?: true"
    end

    test "an argument the backend allows nil for is still rendered allow_nil?: true", %{
      manifest: manifest
    } do
      manifest =
        update_todo_field(manifest, "title_with_prefix", fn field ->
          %{field | arguments: Enum.map(field.arguments, &%{&1 | allow_nil?: true})}
        end)

      source = todo_source(manifest)

      assert source =~ "argument :prefix, :string, allow_nil?: true"
    end
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

    # B2: a hand-crafted/compromised manifest (the loader's trust boundary
    # explicitly does not cover this) must not get its aggregate_filter
    # spliced raw into generated source — same re-verification the calc path
    # already does for `field.expression`.
    test "an unsafe aggregate_filter from a tampered manifest does not get spliced into generated source",
         %{manifest: manifest} do
      injected = ~s|(elem(System.cmd("id", []), 0) == "root") or true|

      manifest =
        update_todo_field(manifest, "comment_count", &%{&1 | aggregate_filter: injected})

      source = todo_source(manifest)

      refute source =~ "System.cmd"
      refute source =~ ~r/count :comment_count, :comments do\n\s*public\? true\n\s*filter/
      assert source =~ ~s|remote("comment_count"|
    end

    # L6 item 6: `relationship_line/4` has no clause for `:many_to_many` (it
    # falls through to the catch-all that emits nothing), so an aggregate
    # naming a many-to-many relationship must not be treated as reproducible
    # — otherwise `aggregate_block/2` renders `count :x, :tags do ... end`
    # against a relationship absent from `relationships do`: uncompilable.
    test "an aggregate over a many-to-many relationship falls back to a remote() proxy, not an uncompilable native aggregate",
         %{manifest: manifest} do
      key = "AshRemote.Backend.Todo"
      todo = manifest.resources[key]

      m2m = %AshRemote.Manifest.Relationship{
        name: "tags",
        type: :many_to_many,
        cardinality: :many,
        destination: "AshRemote.Backend.Comment"
      }

      todo = %{todo | relationships: Map.put(todo.relationships, "tags", m2m)}
      manifest = %{manifest | resources: Map.put(manifest.resources, key, todo)}
      manifest = update_todo_field(manifest, "comment_count", &%{&1 | relationship: "tags"})

      source = todo_source(manifest)

      # The many-to-many relationship itself is correctly omitted (unsupported)…
      refute source =~ "tags"
      # …and the aggregate that named it falls back to a proxy instead of
      # referencing a relationship that doesn't exist in the generated source.
      refute source =~ ~r/count :comment_count, :tags/
      assert source =~ ~s|remote("comment_count"|
      assert {:ok, _ast} = Code.string_to_quoted(source)
    end

    # Same defect, the other cause: a relationship the manifest simply
    # doesn't carry (e.g. private — `Ash.Info.Manifest` only publishes public
    # relationships, so this is the realistic shape a private relationship's
    # name takes here, not a synthetic case).
    test "an aggregate over a relationship absent from the manifest (e.g. private) falls back to a remote() proxy",
         %{manifest: manifest} do
      manifest =
        update_todo_field(manifest, "comment_count", &%{&1 | relationship: "internal_only"})

      source = todo_source(manifest)

      refute source =~ ~r/count :comment_count, :internal_only/
      assert source =~ ~s|remote("comment_count"|
      assert {:ok, _ast} = Code.string_to_quoted(source)
    end
  end

  # L6 item 1: every manifest-sourced name `AshRemote.Gen` splices into
  # generated source as a bare identifier (`:#{name}`, `defmodule
  # #{module} do`, a bare aggregate-kind call) is validated by
  # `AshRemote.Gen.Identifier` before it reaches the source string. Unlike
  # B2's `aggregate_filter` (a *value*, safely gated by falling back to a
  # `remote(...)` proxy), there is no safe fallback rendering for a bad
  # *name* — the field/relationship/module wouldn't mean anything — so the
  # generator raises `AshRemote.Gen.InvalidManifestError` instead.
  describe "identifier safety (L6)" do
    alias AshRemote.Gen.InvalidManifestError

    @injected "evil\nend\n\ndefmodule Elixir.Injected do\n  def pwned, do: System.cmd(\"id\", [])\nend\n\ndefmodule Reopened"

    test "a malicious resource module name is rejected, not spliced into `defmodule ... do`",
         %{manifest: manifest} do
      manifest = rename_todo_module(manifest, "AshRemote.Backend.#{@injected}")

      assert_raise InvalidManifestError, ~r/module name/, fn ->
        AshRemote.Gen.generate(manifest, namespace: "GenVal")
      end
    end

    test "a module name containing a path-traversal-shaped segment is rejected", %{
      manifest: manifest
    } do
      manifest = rename_todo_module(manifest, "AshRemote.Backend.Evil/../../../../tmp/pwned")

      assert_raise InvalidManifestError, fn ->
        AshRemote.Gen.generate(manifest, namespace: "GenVal")
      end
    end

    test "a malicious attribute name is rejected, not spliced as a bare atom", %{
      manifest: manifest
    } do
      manifest = rename_todo_field(manifest, "title", @injected)

      assert_raise InvalidManifestError, ~r/attribute name/, fn -> todo_source(manifest) end
    end

    test "a malicious relationship name is rejected", %{manifest: manifest} do
      manifest = rename_todo_relationship(manifest, "user", @injected)

      assert_raise InvalidManifestError, ~r/relationship name/, fn -> todo_source(manifest) end
    end

    test "a malicious relationship source_attribute is rejected", %{manifest: manifest} do
      manifest =
        update_todo_relationship(manifest, "parent", &%{&1 | source_attribute: @injected})

      assert_raise InvalidManifestError, ~r/relationship attribute name/, fn ->
        todo_source(manifest)
      end
    end

    test "a malicious calculation name is rejected", %{manifest: manifest} do
      manifest = rename_todo_field(manifest, "is_overdue", @injected)

      assert_raise InvalidManifestError, ~r/calculation name/, fn -> todo_source(manifest) end
    end

    test "a malicious calculation argument name is rejected", %{manifest: manifest} do
      manifest =
        update_todo_field(manifest, "title_with_prefix", fn field ->
          %{field | arguments: Enum.map(field.arguments, &%{&1 | name: @injected})}
        end)

      assert_raise InvalidManifestError, ~r/calculation argument name/, fn ->
        todo_source(manifest)
      end
    end

    test "a malicious aggregate name is rejected", %{manifest: manifest} do
      manifest = rename_todo_field(manifest, "comment_count", @injected)

      assert_raise InvalidManifestError, ~r/aggregate name/, fn -> todo_source(manifest) end
    end

    test "an aggregate_kind outside the supported set is rejected (item 5/6 boundary)", %{
      manifest: manifest
    } do
      # `:destroy` is a real, already-existing atom (part of the loader's own
      # closed vocabulary) — this proves the generator's aggregate-kind gate
      # is a *specific allowlist* of supported calls, not merely "any atom".
      manifest = update_todo_field(manifest, "comment_count", &%{&1 | aggregate_kind: :destroy})

      assert_raise InvalidManifestError, ~r/aggregate kind/, fn -> todo_source(manifest) end
    end

    test "a malicious action name is rejected", %{manifest: manifest} do
      manifest = rename_todo_action(manifest, "read", @injected)

      assert_raise InvalidManifestError, ~r/action name/, fn -> todo_source(manifest) end
    end

    test "a malicious enum value is rejected, not spliced as a bare atom", %{manifest: manifest} do
      manifest = set_status_enum_values(manifest, ["pending", @injected])

      assert_raise InvalidManifestError, ~r/enum value/, fn ->
        AshRemote.Gen.generate(manifest, namespace: "GenVal")
      end
    end

    test "a malicious primary key name is rejected", %{manifest: manifest} do
      key = "AshRemote.Backend.Todo"
      todo = %{manifest.resources[key] | primary_key: [@injected]}
      manifest = %{manifest | resources: Map.put(manifest.resources, key, todo)}

      assert_raise InvalidManifestError, ~r/primary key attribute name/, fn ->
        todo_source(manifest)
      end
    end

    test "benign-but-unusual identifiers (trailing ?) still generate cleanly, no partial/syntax-broken source",
         %{manifest: manifest} do
      manifest = rename_todo_field(manifest, "completed", "is_done?")

      source = todo_source(manifest)

      assert source =~ "attribute :is_done?,"
      assert {:ok, _ast} = Code.string_to_quoted(source)
    end

    test "an unmodified manifest still generates without raising (no false positives)", %{
      manifest: manifest
    } do
      source = todo_source(manifest)
      assert {:ok, _ast} = Code.string_to_quoted(source)
    end
  end
end
