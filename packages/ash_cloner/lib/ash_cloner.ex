defmodule AshCloner do
  @moduledoc """
  Clone Ash resources into a user's application with Igniter, and keep them
  up to date without clobbering user edits.

  Sharing Ash resources through packages is hard: a library can't just ship
  resource modules, because the user needs to own, rename, and extend them.
  AshCloner lets a library author write real, compilable, testable resources
  (in the library itself, or its example app) and ship an installer that
  copies them into the user's codebase — then re-run later to pick up new
  entities from the library without touching what the user changed.

  Two halves:

    * `AshCloner.SourceCloner` — turns resource source files from a
      dependency into `AshCloner.Definition`s, re-namespaced for the user's
      app.
    * `apply_definitions/3` — applies definitions to an `Igniter.t()`:
      modules that don't exist are created whole; existing modules only gain
      the entities they're missing, and any disagreement (drift) is reported
      or interactively resolved.

  ## Ownership model

  No markers, no bookkeeping: ownership is definition-set membership,
  recomputed on every run. An existing module is never rewritten — entities
  the definitions carry are ensured by name, everything else in the file is
  the user's. Re-applying unchanged definitions is a no-op.

  ## Dry runs

  `apply_definitions/3` only ever mutates the passed `Igniter.t()` — it
  never touches the filesystem itself. Any `Igniter.Mix.Task` built on it
  therefore supports Igniter's standard `--dry-run` (print proposed changes
  without writing) and `--check` flags for free.
  """

  defmodule PathEscapeError do
    defexception [:message]
  end

  @doc """
  Apply definitions to an igniter: create missing modules whole, ensure
  entities on existing ones, and reconcile drift.

  ## Options

    * `:output` — directory newly created modules are written under
      (default `"lib"`)
    * `:path_for` — `(module_string -> path)` override for placing new
      files; defaults to `output_path(output, module)`
    * `:interactive` — resolve drift by prompting per entity instead of
      warning (default `false`; keeping the user's version is always the
      default answer)
    * `:labels` — words used in drift warnings and prompts:
      `:definitions` names where the definitions came from (default
      `"the source definitions"`), `:upstream` names who else could have
      changed them (default `"upstream"`). E.g.
      `[definitions: "the manifest", upstream: "the server"]`.
  """
  @spec apply_definitions(Igniter.t(), [AshCloner.Definition.t() | map()], keyword()) ::
          Igniter.t()
  def apply_definitions(igniter, definitions, opts \\ []) do
    output = opts[:output] || "lib"
    path_for = opts[:path_for] || (&output_path(output, &1))
    interactive? = opts[:interactive] || false
    labels = labels(opts)

    Enum.reduce(definitions, igniter, fn definition, igniter ->
      module = Igniter.Project.Module.parse(definition.module)
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, module)

      if exists? do
        igniter
        |> AshCloner.Engine.ensure_entities(module, definition)
        |> AshCloner.Engine.Drift.reconcile(module, definition, interactive?, labels)
      else
        Igniter.create_new_file(igniter, path_for.(definition.module), definition.source)
      end
    end)
  end

  @doc """
  The conventional file path for a module under `output`
  (`Macro.underscore/1` + `.ex`), asserting the resolved path can never
  escape the output root (raises `AshCloner.PathEscapeError` otherwise).
  """
  @spec output_path(String.t(), String.t()) :: Path.t()
  def output_path(output, module) do
    path = Path.join(output, Macro.underscore(module) <> ".ex")
    :ok = assert_contained!(output, path, module)
    path
  end

  # A crafted module name can't actually reach an escaping path through
  # `Macro.underscore/1` (it provably never emits a literal ".."), but the
  # containment assertion stays as the belt-and-suspenders layer so a future
  # change to the path derivation can't silently reopen the gap.
  # `@doc false` (not `defp`) purely so tests can call it directly with a
  # synthetic escaping path.
  @doc false
  def assert_contained!(output, path, module) do
    root = Path.expand(output)
    resolved = Path.expand(path)

    if resolved == root or String.starts_with?(resolved, root <> "/") do
      :ok
    else
      raise PathEscapeError,
        message:
          "generated path #{inspect(path)} (from module #{inspect(module)}) escapes the " <>
            "configured output root #{inspect(output)}"
    end
  end

  defp labels(opts) do
    labels = opts[:labels] || []

    %{
      definitions: labels[:definitions] || "the source definitions",
      upstream: labels[:upstream] || "upstream"
    }
  end
end
