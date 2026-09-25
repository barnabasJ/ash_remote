defmodule AshCloner.SourceCloner do
  @moduledoc """
  Turn real resource source files from a dependency into
  `AshCloner.Definition`s the apply engine can install into a user's app.

  This is the authoring model the package exists for: a library writes
  real, compilable, *testable* Ash resources (in the library itself or its
  example app) and ships an installer that clones them — instead of
  hand-maintaining Igniter templates. Because the clone is source-based,
  everything the author wrote survives verbatim: changes, preparations,
  helper functions, comments.

  Module names are re-namespaced by prefix swap: the source library's common
  prefix (or an explicit `:prefix`) is replaced with the user's `:namespace`
  in the `defmodule` head *and* every qualified reference in the body —
  `alias`/`use`/`import` directives and inline references alike, since all
  of them are `__aliases__` nodes.

  ## Known limitations

  Only `__aliases__` nodes are rewritten. Module names built at runtime
  (`Module.concat/1`, string interpolation) or written as raw atoms
  (`:"Elixir.MyLib.Post"`) are not. A bare re-`alias`ed prefix
  (`alias MyLib.Blog` + `Blog.Post` in the body) is also not followed —
  alias the full module instead.
  """

  alias AshCloner.{Definition, Namespace, Sections}

  @doc """
  Clone the given (compiled) modules by locating their source files.

  Source is found via `module.module_info(:compile)[:source]`, which for a
  dependency points into the consuming project's `deps/`. Modules-first is
  the recommended API for library authors: the compiler keeps the shipped
  list honest.

  ## Options

    * `:namespace` (required) — target module prefix, e.g. `"UserApp.Blog"`
      (string or module)
    * `:prefix` — source prefix to strip; defaults to
      `AshCloner.Namespace.common_prefix/1` over the given modules
    * `:sources` — `%{module => path}` overrides for source lookup
      (releases with stripped debug info, generated modules, …)
    * `:otp_app` — when set, rewrites the `otp_app:` value inside
      `use Ash.Resource` / `use Ash.Domain` options
  """
  @spec from_modules([module()], keyword()) :: [Definition.t()]
  def from_modules(modules, opts) do
    source_overrides = opts[:sources] || %{}

    asts =
      Enum.map(modules, fn module ->
        name = inspect(module)
        path = source_overrides[module] || source_path!(module)

        path
        |> File.read!()
        |> Sourceror.parse_string!()
        |> find_defmodule!(name, path)
      end)

    definitions(asts, opts)
  end

  @doc """
  Clone every top-level `defmodule` found in the given source strings.

  Same options as `from_modules/2` (minus `:sources`); `:prefix` defaults to
  the common prefix of the parsed module names.
  """
  @spec from_sources([String.t()], keyword()) :: [Definition.t()]
  def from_sources(sources, opts) do
    asts =
      Enum.flat_map(sources, fn source ->
        source |> Sourceror.parse_string!() |> top_level_defmodules()
      end)

    definitions(asts, opts)
  end

  @doc "Single-string convenience for `from_sources/2`."
  @spec from_source(String.t(), keyword()) :: [Definition.t()]
  def from_source(source, opts), do: from_sources([source], opts)

  # --- pipeline --------------------------------------------------------------

  defp definitions(asts, opts) do
    namespace = normalize_namespace(Keyword.fetch!(opts, :namespace))
    namespace_atoms = segments_to_atoms(namespace)

    names = Enum.map(asts, &module_name/1)
    prefix = normalize_prefix(opts[:prefix]) || Namespace.common_prefix(names)
    prefix_atoms = segments_to_atoms(prefix)
    cloned_segments = Enum.map(names, &segments_to_atoms(String.split(&1, ".")))

    asts
    |> Enum.map(&rename(&1, prefix_atoms, namespace_atoms, cloned_segments))
    |> Enum.map(&rewrite_otp_app(&1, opts[:otp_app]))
    |> Enum.map(&to_definition/1)
  end

  defp to_definition({:defmodule, _, _} = ast) do
    body = do_body(ast)
    kind = classify(body)
    zipper = Sourceror.Zipper.zip(body)

    fields = [
      module: module_name(ast),
      kind: kind,
      source: Sourceror.to_string(ast) <> "\n"
    ]

    fields =
      case kind do
        :resource -> Keyword.put(fields, :entities, extract_entities(zipper))
        :domain -> Keyword.put(fields, :resources, domain_resources(zipper))
        :verbatim -> fields
      end

    Definition.new(fields)
  end

  # --- source lookup ---------------------------------------------------------

  defp source_path!(module) do
    unless Code.ensure_loaded?(module) do
      raise ArgumentError, "module #{inspect(module)} is not available — is it compiled?"
    end

    case module.module_info(:compile)[:source] do
      nil ->
        raise ArgumentError,
              "no compile-time source recorded for #{inspect(module)} — " <>
                "pass its path via the :sources option"

      source ->
        path = to_string(source)

        if File.exists?(path) do
          path
        else
          raise ArgumentError,
                "source of #{inspect(module)} recorded as #{path}, which does not exist — " <>
                  "pass its path via the :sources option"
        end
    end
  end

  defp find_defmodule!(file_ast, name, path) do
    file_ast
    |> top_level_defmodules()
    |> Enum.find(&(module_name(&1) == name)) ||
      raise ArgumentError, "no `defmodule #{name}` found in #{path}"
  end

  defp top_level_defmodules({:defmodule, _, _} = ast), do: [ast]

  defp top_level_defmodules({:__block__, _, statements}) do
    Enum.filter(statements, &match?({:defmodule, _, _}, &1))
  end

  defp top_level_defmodules(_other), do: []

  defp module_name({:defmodule, _, [{:__aliases__, _, segments} | _]}) do
    Enum.map_join(segments, ".", &to_string/1)
  end

  defp do_body({:defmodule, _, [_target, do_keyword]}) when is_list(do_keyword) do
    Enum.find_value(do_keyword, fn
      {{:__block__, _, [:do]}, body} -> body
      {:do, body} -> body
      _ -> nil
    end)
  end

  # --- re-namespacing --------------------------------------------------------

  # One rule covers the defmodule head, alias/use/import directives, and
  # inline qualified references: they're all `__aliases__` nodes. Metadata is
  # preserved so Sourceror keeps comments and formatting intact.
  defp rename(ast, prefix_atoms, namespace_atoms, cloned_segments) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, segments} = node ->
        cond do
          prefix_atoms != [] and List.starts_with?(segments, prefix_atoms) ->
            {:__aliases__, meta, namespace_atoms ++ Enum.drop(segments, length(prefix_atoms))}

          # An empty prefix would "match" every alias in the file (Ash.Resource
          # included) — nest only the cloned modules' own names instead.
          prefix_atoms == [] and segments in cloned_segments ->
            {:__aliases__, meta, namespace_atoms ++ segments}

          true ->
            node
        end

      other ->
        other
    end)
  end

  defp rewrite_otp_app(ast, nil), do: ast

  defp rewrite_otp_app(ast, app) when is_atom(app) do
    Macro.prewalk(ast, fn
      {:use, meta, [{:__aliases__, _, [:Ash, kind]} = target, use_opts]}
      when kind in [:Resource, :Domain] and is_list(use_opts) ->
        {:use, meta, [target, Enum.map(use_opts, &replace_otp_app(&1, app))]}

      other ->
        other
    end)
  end

  defp replace_otp_app({{:__block__, _, [:otp_app]} = key, {:__block__, meta, [_old]}}, app),
    do: {key, {:__block__, meta, [app]}}

  defp replace_otp_app({:otp_app, _old}, app), do: {:otp_app, app}
  defp replace_otp_app(other, _app), do: other

  # --- classification and extraction -----------------------------------------

  defp classify(body) do
    body
    |> body_statements()
    |> Enum.find_value(:verbatim, fn
      {:use, _, [{:__aliases__, _, [:Ash, :Resource]} | _]} -> :resource
      {:use, _, [{:__aliases__, _, [:Ash, :Domain]} | _]} -> :domain
      _ -> nil
    end)
  end

  defp body_statements({:__block__, _, statements}), do: statements
  defp body_statements(nil), do: []
  defp body_statements(statement), do: [statement]

  # Per-section `{name, code}` snippets — the unit of non-destructive
  # updates. Statements a section holds that aren't entity declarations
  # (comments live on entity nodes anyway) stay in `source` only.
  defp extract_entities(zipper) do
    named =
      Map.new(Sections.section_calls(), fn {section, calls} ->
        entities =
          section_statements(zipper, section)
          |> Enum.flat_map(fn stmt ->
            with {call, _, [_ | _]} <- stmt,
                 true <- call in calls,
                 name when not is_nil(name) <- Sections.entity_name(stmt) do
              [{name, Sourceror.to_string(stmt)}]
            else
              _ -> []
            end
          end)

        {section, entities}
      end)

    validations =
      section_statements(zipper, :validations)
      |> Enum.flat_map(fn
        {:validate, _, [_ | _]} = stmt ->
          code = Sourceror.to_string(stmt)
          [{code, code}]

        _ ->
          []
      end)

    Map.put(named, :validations, validations)
  end

  defp domain_resources(zipper) do
    section_statements(zipper, :resources)
    |> Enum.flat_map(fn
      {:resource, _, [{:__aliases__, _, segments} | _]} ->
        [Enum.map_join(segments, ".", &to_string/1)]

      _ ->
        []
    end)
  end

  defp section_statements(zipper, section) do
    case Sections.enter_section(zipper, section) do
      {:ok, inner} -> Sections.statements(inner)
      :error -> []
    end
  end

  # --- option normalization ---------------------------------------------------

  defp normalize_namespace(namespace) when is_atom(namespace) do
    namespace |> to_string() |> String.replace_prefix("Elixir.", "") |> String.split(".")
  end

  defp normalize_namespace(namespace) when is_binary(namespace),
    do: String.split(namespace, ".")

  defp normalize_prefix(nil), do: nil
  defp normalize_prefix(prefix) when is_list(prefix), do: prefix
  defp normalize_prefix(prefix) when is_binary(prefix), do: String.split(prefix, ".")

  defp normalize_prefix(prefix) when is_atom(prefix),
    do: prefix |> to_string() |> String.replace_prefix("Elixir.", "") |> String.split(".")

  defp segments_to_atoms(segments), do: Enum.map(segments, &String.to_atom/1)
end
