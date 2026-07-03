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

  ## Options

    * `--manifest` / `-m` — path or URL to the manifest JSON (required)
    * `--namespace` / `-n` — module prefix for generated resources, e.g. `MyApp.Remote` (required)
    * `--domain` — client domain module (defaults to `<namespace>.Domain`)
    * `--output` / `-o` — output directory (defaults to `lib`)
    * `--base-url` — bake a base URL into each `remote` block (otherwise resolved
      at call time from `config :ash_remote, :base_url`)

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
        base_url: :string
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

    Enum.reduce(modules, igniter, fn definition, igniter ->
      module = Igniter.Project.Module.parse(definition.module)
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, module)

      if exists? do
        ensure_entities(igniter, module, definition)
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

  defp ensure_entities(igniter, module, %{kind: :domain, resources: resources}) do
    Enum.reduce(resources, igniter, fn resource, igniter ->
      Ash.Domain.Igniter.add_resource_reference(
        igniter,
        module,
        Igniter.Project.Module.parse(resource)
      )
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

  defp require_option!(options, key) do
    case options[key] do
      nil -> Mix.raise("--#{key} is required")
      value -> value
    end
  end
end
