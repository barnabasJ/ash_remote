defmodule Mix.Tasks.AshCloner.Clone do
  @shortdoc "Clone Ash resources from a dependency into this app"
  @moduledoc """
  Clone Ash resources (their actual source) from a dependency into this
  application, re-namespaced, and keep them updatable.

      mix ash_cloner.clone --modules MODULES --namespace NAMESPACE [options]

  Re-running is non-destructive: a module that doesn't exist yet is created
  whole; an existing module only gains the entities it's missing
  (attributes, relationships, validations, calculations, aggregates,
  actions, domain resource entries). Anything you've added or edited by
  hand is left untouched. Disagreements (drift) are reported as warnings,
  or resolved per entity with `--interactive`.

  Library authors typically wrap this in their own installer task (see the
  README) so users run e.g. `mix my_lib.install --namespace MyApp.Feature`.

  ## Options

    * `--modules` / `-m` — comma-separated modules to clone, e.g.
      `MyLib.Blog.Post,MyLib.Blog.Domain` (required)
    * `--namespace` / `-n` — module prefix the clones live under, e.g.
      `MyApp.Blog` (required)
    * `--prefix` — source prefix to strip (defaults to the modules' common
      prefix)
    * `--output` / `-o` — output directory (defaults to `lib`)
    * `--otp-app` — rewrite the `otp_app:` option inside
      `use Ash.Resource`/`use Ash.Domain` to this app
    * `--interactive` — resolve detected drift by prompting instead of
      warning

  Standard Igniter flags `--dry-run` (preview all changes without writing
  anything) and `--check` are supported.
  """
  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _parent) do
    %Igniter.Mix.Task.Info{
      group: :ash_cloner,
      schema: [
        modules: :string,
        namespace: :string,
        prefix: :string,
        output: :string,
        otp_app: :string,
        interactive: :boolean
      ],
      aliases: [m: :modules, n: :namespace, o: :output]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    options = igniter.args.options

    modules =
      options
      |> require_option!(:modules)
      |> String.split(",", trim: true)
      |> Enum.map(&Igniter.Project.Module.parse/1)

    definitions =
      AshCloner.SourceCloner.from_modules(modules,
        namespace: require_option!(options, :namespace),
        prefix: options[:prefix],
        otp_app: options[:otp_app] && String.to_atom(options[:otp_app])
      )

    AshCloner.apply_definitions(igniter, definitions,
      output: options[:output] || "lib",
      interactive: options[:interactive] || false,
      labels: [definitions: "the library's resources", upstream: "the library"]
    )
  end

  defp require_option!(options, key) do
    case options[key] do
      nil -> Mix.raise("--#{key} is required")
      value -> value
    end
  end
end
