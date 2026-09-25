defmodule Mix.Tasks.AshRemote.Gen do
  @shortdoc "Generate standalone Ash resources from an ash_remote manifest"
  @moduledoc """
  Generate standalone Ash client resources from a published `Ash.Info.Manifest`.

      mix ash_remote.gen --manifest MANIFEST --namespace NAMESPACE [options]

  Regeneration is non-destructive: a module that doesn't exist yet is created
  whole; an existing module only gains the manifest entities it's missing
  (attributes, relationships, validations, calculations, aggregates, actions,
  domain resource entries).
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

    definitions =
      AshRemote.Gen.generate(manifest,
        namespace: namespace,
        domain: options[:domain],
        base_url: options[:base_url]
      )

    # The create/ensure-missing/drift-reconcile engine lives in ash_cloner;
    # `output_path/2` stays ours for its manifest-specific error type.
    AshCloner.apply_definitions(igniter, definitions,
      interactive: options[:interactive] || false,
      path_for: &output_path(output, &1),
      labels: [definitions: "the manifest", upstream: "the server"]
    )
  end

  # `AshRemote.Gen.generate/2` already refuses (via `AshRemote.Gen.Identifier`)
  # any manifest module name whose `Macro.underscore/1` could contain a `/` or
  # `..`, so `definition.module` reaching this function is never
  # attacker-controlled in practice. `assert_contained!/3` is the
  # belt-and-suspenders second layer the L6 task spec asks for regardless:
  # an explicit, independently-testable assertion that the resolved path
  # never escapes `output`, so a future change to either the identifier
  # validator or `Macro.underscore/1` itself can't silently reopen the gap.
  # `@doc false` (not `defp`) purely so tests can call these directly.
  @doc false
  def output_path(output, module) do
    path = Path.join(output, Macro.underscore(module) <> ".ex")
    :ok = assert_contained!(output, path, module)
    path
  end

  @doc false
  def assert_contained!(output, path, module) do
    root = Path.expand(output)
    resolved = Path.expand(path)

    if resolved == root or String.starts_with?(resolved, root <> "/") do
      :ok
    else
      raise AshRemote.Gen.InvalidManifestError,
        message:
          "generated path #{inspect(path)} (from module #{inspect(module)}) escapes the " <>
            "configured output root #{inspect(output)}"
    end
  end

  defp require_option!(options, key) do
    case options[key] do
      nil -> Mix.raise("--#{key} is required")
      value -> value
    end
  end
end
