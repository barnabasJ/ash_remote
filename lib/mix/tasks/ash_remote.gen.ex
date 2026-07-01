defmodule Mix.Tasks.AshRemote.Gen do
  @shortdoc "Generate standalone Ash resources from an ash_remote manifest"
  @moduledoc """
  Generate standalone Ash client resources from a published `Ash.Info.Manifest`.

      mix ash_remote.gen --manifest MANIFEST --namespace NAMESPACE [options]

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

    Enum.reduce(modules, igniter, fn {module, source}, igniter ->
      path = Path.join(output, Macro.underscore(module) <> ".ex")
      Igniter.create_new_file(igniter, path, source, on_exists: :overwrite)
    end)
  end

  defp require_option!(options, key) do
    case options[key] do
      nil -> Mix.raise("--#{key} is required")
      value -> value
    end
  end
end
