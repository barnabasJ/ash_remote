defmodule Mix.Tasks.AshRemote.Gen do
  @shortdoc "Generate standalone Ash resources from an ash_remote manifest"
  @moduledoc """
  Generate standalone Ash client resources from a published `Ash.Info.Manifest`.

      mix ash_remote.gen --manifest MANIFEST --namespace NAMESPACE [options]

  Regeneration is non-destructive: a module that doesn't exist yet is created
  whole; an existing module only gains the manifest entities it's missing
  (attributes, relationships, calculations, actions, domain resource entries).
  Anything you've added or edited by hand is left untouched — the manifest
  defines what's managed, everything else is yours.

  Drift between an existing module and the manifest is detected and surfaced:
  entities whose definition differs from the manifest, and entities present in
  the file but absent from the manifest (your additions — or things removed on
  the server). By default each is reported as a warning. With `--interactive`
  you decide per entity: keep your version (the default answer), or take the
  manifest's (replacing a changed entity / removing an absent one).

  ## Options

    * `--manifest` / `-m` — path or URL to the manifest JSON (required)
    * `--namespace` / `-n` — module prefix for generated resources, e.g. `MyApp.Remote` (required)
    * `--domain` — client domain module (defaults to `<namespace>.Domain`)
    * `--output` / `-o` — output directory (defaults to `lib`)
    * `--base-url` — bake a base URL into each `remote` block (otherwise resolved
      at call time from `config :ash_remote, :base_url`)
    * `--interactive` — resolve detected drift by prompting instead of warning

  Standard Igniter flags `--dry-run` and `--check` are supported.
  """
  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _parent) do
    %Igniter.Mix.Task.Info{
      group: :ash_remote,
      schema: [
        manifest: :string,
        namespace: :string,
        domain: :string,
        output: :string,
        base_url: :string,
        interactive: :boolean
      ],
      aliases: [m: :manifest, n: :namespace, o: :output]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    options = igniter.args.options

    manifest_path = require_option!(options, :manifest)
    namespace = require_option!(options, :namespace)
    output = options[:output] || "lib"

    manifest = AshRemote.Manifest.Loader.load!(manifest_path)

    modules =
      AshRemote.Gen.generate(manifest,
        namespace: namespace,
        domain: options[:domain],
        base_url: options[:base_url]
      )

    interactive? = options[:interactive] || false

    Enum.reduce(modules, igniter, fn definition, igniter ->
      module = Igniter.Project.Module.parse(definition.module)
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, module)

      if exists? do
        igniter
        |> ensure_entities(module, definition)
        |> reconcile_drift(module, definition, interactive?)
      else
        path = Path.join(output, Macro.underscore(definition.module) <> ".ex")
        Igniter.create_new_file(igniter, path, definition.source)
      end
    end)
  end

  # Existing modules are never rewritten — the manifest's entities are ensured
  # by name and everything else (user additions and edits) is left alone.
  defp ensure_entities(igniter, module, %{kind: :resource, entities: entities}) do
    igniter
    |> ensure_all(entities.attributes, module, &Ash.Resource.Igniter.add_new_attribute/4)
    |> ensure_all(entities.relationships, module, &Ash.Resource.Igniter.add_new_relationship/4)
    |> ensure_all(entities.calculations, module, &add_new_calculation/4)
    |> ensure_all(entities.actions, module, &Ash.Resource.Igniter.add_new_action/4)
  end

  # Not `Ash.Domain.Igniter.add_resource_reference/3`: its domain discovery
  # (app config + changed-source scan) doesn't reliably see our generated
  # domain and then "upgrades" it with a second `use Ash.Domain`. We know the
  # module is our domain, so ensure the reference directly.
  defp ensure_entities(igniter, module, %{kind: :domain, resources: resources}) do
    Enum.reduce(resources, igniter, fn resource, igniter ->
      resource = Igniter.Project.Module.parse(resource)

      Igniter.Project.Module.find_and_update_module!(igniter, module, fn zipper ->
        case move_to_entity(zipper, %{section: :resources, name: resource}) do
          {:ok, _found} ->
            {:ok, zipper}

          :error ->
            case enter_section(zipper, :resources) do
              {:ok, section} ->
                {:ok, Igniter.Code.Common.add_code(section, "resource #{inspect(resource)}")}

              :error ->
                {:ok,
                 Igniter.Code.Common.add_code(
                   zipper,
                   "resources do\n  resource #{inspect(resource)}\nend"
                 )}
            end
        end
      end)
    end)
  end

  # Named types (enums/NewTypes): nothing to reconcile entity-wise.
  defp ensure_entities(igniter, _module, %{kind: :type}), do: igniter

  defp ensure_all(igniter, entities, module, add_new) do
    Enum.reduce(entities, igniter, fn {name, code}, igniter ->
      add_new.(igniter, module, name, code)
    end)
  end

  # `Ash.Resource.Igniter.defines_calculation/3` (through at least 3.29.3) only
  # matches `calculate` calls of arity 3, missing the `calculate ... do ... end`
  # form our stubs use — so existing calculations would be re-added on every
  # regen. Same check with arity 3-or-4; candidate upstream fix.
  defp add_new_calculation(igniter, module, name, code) do
    {igniter, defines?} = defines_calculation(igniter, module, name)

    if defines? do
      igniter
    else
      Ash.Resource.Igniter.add_calculation(igniter, module, code)
    end
  end

  defp defines_calculation(igniter, module, name) do
    Spark.Igniter.find(igniter, module, fn _, zipper ->
      with {:ok, zipper} <-
             Igniter.Code.Function.move_to_function_call_in_current_scope(
               zipper,
               :calculations,
               1
             ),
           {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper),
           {:ok, _zipper} <-
             Igniter.Code.Function.move_to_function_call_in_current_scope(
               zipper,
               :calculate,
               [3, 4],
               &Igniter.Code.Function.argument_equals?(&1, 0, name)
             ) do
        {:ok, true}
      else
        _ -> :error
      end
    end)
    |> case do
      {:ok, igniter, _module, _value} -> {igniter, true}
      {:error, igniter} -> {igniter, false}
    end
  end

  # --- drift detection -------------------------------------------------------
  #
  # After missing entities are ensured, an existing module can still disagree
  # with the manifest in two ways:
  #
  #   * :changed — an entity exists in both but is defined differently
  #     (a user edit, or the server changed its definition)
  #   * :extra   — an entity exists in the file but not in the manifest
  #     (a user addition, or the server removed it)
  #
  # We can't tell which side is right, so nothing is done automatically:
  # by default each finding becomes a warning; with --interactive the user
  # decides per entity (keeping their version is always the default answer).

  @section_calls [
    attributes: [
      :attribute,
      :uuid_primary_key,
      :uuid_v7_primary_key,
      :integer_primary_key,
      :create_timestamp,
      :update_timestamp
    ],
    relationships: [:belongs_to, :has_many, :has_one, :many_to_many],
    calculations: [:calculate],
    actions: [:read, :create, :update, :destroy, :action]
  ]

  defp reconcile_drift(igniter, module, definition, interactive?) do
    {igniter, drift} = detect_drift(igniter, module, definition)

    Enum.reduce(drift, igniter, fn finding, igniter ->
      cond do
        not interactive? ->
          Igniter.add_warning(igniter, warning(module, finding))

        keep?(module, finding) ->
          igniter

        finding.kind == :changed ->
          replace_entity(igniter, module, finding)

        finding.kind == :extra ->
          remove_entity(igniter, module, finding)
      end
    end)
  end

  defp detect_drift(igniter, module, %{kind: :resource, entities: entities}) do
    Spark.Igniter.find(igniter, module, fn _, zipper ->
      drift =
        Enum.flat_map(@section_calls, fn {section, calls} ->
          section_drift(zipper, section, calls, Map.fetch!(entities, section))
        end)

      {:ok, drift}
    end)
    |> case do
      {:ok, igniter, _module, drift} -> {igniter, drift}
      {:error, igniter} -> {igniter, []}
    end
  end

  defp detect_drift(igniter, module, %{kind: :domain, resources: resources}) do
    expected = Enum.map(resources, &Igniter.Project.Module.parse/1)

    Spark.Igniter.find(igniter, module, fn _, zipper ->
      drift =
        with {:ok, zipper} <- enter_section(zipper, :resources) do
          zipper
          |> statements()
          |> Enum.flat_map(fn
            {:resource, _, [{:__aliases__, _, parts} | _]} = stmt ->
              if Module.concat(parts) in expected do
                []
              else
                [
                  %{
                    section: :resources,
                    name: Module.concat(parts),
                    kind: :extra,
                    current: Sourceror.to_string(stmt)
                  }
                ]
              end

            _ ->
              []
          end)
        else
          _ -> []
        end

      {:ok, drift}
    end)
    |> case do
      {:ok, igniter, _module, drift} -> {igniter, drift}
      {:error, igniter} -> {igniter, []}
    end
  end

  defp detect_drift(igniter, _module, %{kind: :type}), do: {igniter, []}

  defp section_drift(zipper, section, calls, manifest_entities) do
    with {:ok, zipper} <- enter_section(zipper, section) do
      zipper
      |> statements()
      |> Enum.flat_map(fn stmt ->
        with {call, _, [_ | _]} <- stmt,
             true <- call in calls,
             name when not is_nil(name) <- entity_name(stmt) do
          entity_drift(section, name, stmt, List.keyfind(manifest_entities, name, 0))
        else
          _ -> []
        end
      end)
    else
      _ -> []
    end
  end

  defp entity_drift(section, name, stmt, nil) do
    [%{section: section, name: name, kind: :extra, current: Sourceror.to_string(stmt)}]
  end

  defp entity_drift(section, name, stmt, {_name, manifest_code}) do
    if equivalent?(stmt, Sourceror.parse_string!(manifest_code)) do
      []
    else
      [
        %{
          section: section,
          name: name,
          kind: :changed,
          current: Sourceror.to_string(stmt),
          manifest: manifest_code
        }
      ]
    end
  end

  defp enter_section(zipper, section) do
    with {:ok, zipper} <-
           Igniter.Code.Function.move_to_function_call_in_current_scope(zipper, section, 1) do
      Igniter.Code.Common.move_to_do_block(zipper)
    end
  end

  defp statements(zipper) do
    case Sourceror.Zipper.node(zipper) do
      {:__block__, _, stmts} -> stmts
      stmt -> [stmt]
    end
  end

  defp entity_name({_call, _, [first | _]}) do
    case first do
      name when is_atom(name) -> name
      {:__block__, _, [name]} when is_atom(name) -> name
      _ -> nil
    end
  end

  # Definition equality modulo formatting: strip AST metadata (line numbers,
  # parens, literal encodings) and compare.
  defp equivalent?(left, right), do: strip_meta(left) == strip_meta(right)

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {name, _meta, args} -> {name, [], args}
      other -> other
    end)
  end

  # --- drift resolution ------------------------------------------------------

  defp keep?(module, %{kind: :changed} = finding) do
    Igniter.Util.IO.yes?("""

    #{inspect(module)}: #{finding.section} entity #{inspect(finding.name)} differs from the manifest.

    current:
    #{indent(finding.current)}

    manifest:
    #{indent(finding.manifest)}

    Keep the current version? (n replaces it with the manifest version)
    """)
  end

  defp keep?(module, %{kind: :extra} = finding) do
    Igniter.Util.IO.yes?("""

    #{inspect(module)}: #{finding.section} entity #{inspect(finding.name)} is not in the manifest —
    either you added it, or it was removed on the server.

    #{indent(finding.current)}

    Keep it? (n removes it)
    """)
  end

  defp warning(module, %{kind: :changed} = finding) do
    "#{inspect(module)}: #{finding.section} entity #{inspect(finding.name)} differs from the " <>
      "manifest (kept as-is — rerun with --interactive to resolve)"
  end

  defp warning(module, %{kind: :extra} = finding) do
    "#{inspect(module)}: #{finding.section} entity #{inspect(finding.name)} is not in the " <>
      "manifest — user-added, or removed on the server (kept as-is — rerun with --interactive to resolve)"
  end

  defp replace_entity(igniter, module, finding) do
    Igniter.Project.Module.find_and_update_module!(igniter, module, fn zipper ->
      with {:ok, zipper} <- move_to_entity(zipper, finding) do
        {:ok, Igniter.Code.Common.replace_code(zipper, finding.manifest)}
      end
    end)
  end

  defp remove_entity(igniter, module, finding) do
    Igniter.Project.Module.find_and_update_module!(igniter, module, fn zipper ->
      with {:ok, zipper} <- move_to_entity(zipper, finding) do
        {:ok, Sourceror.Zipper.remove(zipper)}
      end
    end)
  end

  defp move_to_entity(zipper, %{section: :resources, name: module}) do
    with {:ok, zipper} <- enter_section(zipper, :resources) do
      Igniter.Code.Function.move_to_function_call_in_current_scope(
        zipper,
        :resource,
        [1, 2],
        &Igniter.Code.Function.argument_equals?(&1, 0, module)
      )
    end
  end

  defp move_to_entity(zipper, %{section: section, name: name}) do
    calls = Keyword.fetch!(@section_calls, section)

    with {:ok, zipper} <- enter_section(zipper, section) do
      Enum.reduce_while(calls, :error, fn call, _acc ->
        case Igniter.Code.Function.move_to_function_call_in_current_scope(
               zipper,
               call,
               [1, 2, 3, 4],
               &Igniter.Code.Function.argument_equals?(&1, 0, name)
             ) do
          {:ok, zipper} -> {:halt, {:ok, zipper}}
          :error -> {:cont, :error}
        end
      end)
    end
  end

  defp indent(code) do
    code |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))
  end

  defp require_option!(options, key) do
    case options[key] do
      nil -> Mix.raise("--#{key} is required")
      value -> value
    end
  end
end
