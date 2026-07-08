defmodule AshRemote.Gen.InvalidManifestError do
  @moduledoc """
  Raised when a manifest field that becomes generated Elixir source — a
  module name, or a bare field/relationship/aggregate/action/enum identifier —
  isn't safe to splice into source as-is.

  The manifest is external input; the loader's trust requirement (R-8) covers
  its own vocabulary atoms, but a hand-crafted/compromised manifest is
  explicitly not something the loader defends against for free-text fields
  like names (see `AshRemote.Manifest.Loader`'s moduledoc and B2). This is the
  generator's corresponding safety gate for *identifiers* — the counterpart to
  `AshRemote.Literal.safe?/1` and `AshRemote.Expression.safe?/1`, which gate
  *values* (validation opts, calculation/aggregate filter expressions) rather
  than the bare names those values are attached to.
  """
  defexception [:message]
end

defmodule AshRemote.Gen.Identifier do
  @moduledoc """
  Validates manifest-supplied strings that `AshRemote.Gen` splices into
  generated source as bare identifiers — atoms (`:name`) or module aliases
  (`defmodule Some.Module do`) — rather than as properly-escaped literals.

  Every name that reaches generated source through simple string
  interpolation is a code-injection point unless validated first: a resource,
  field, relationship, or aggregate name containing e.g. `"foo\\nend\\ndefmodule
  Evil do"` would inject arbitrary top-level Elixir into the generated file. A
  module name is a second, independent injection point (via `defmodule` on
  the raw string) *and* the seed for the generated file's path
  (`Macro.underscore(module) <> ".ex"`) — validating it here also closes the
  file off from ever seeing attacker-controlled path segments, which is the
  more robust fix for the path-safety concern than trying to sanitize an
  already-computed path after the fact (see
  `Mix.Tasks.AshRemote.Gen.output_path/2` for the belt-and-suspenders
  containment check kept anyway).

  Trusted, developer-supplied input (CLI `--namespace`/`--domain`, or atoms
  that are already literals in our own source, like the `:id` primary-key
  default) is not manifest-derived and is not validated here — only
  manifest-sourced strings are.
  """

  alias AshRemote.Gen.InvalidManifestError

  # A bare Elixir identifier: letters/digits/underscore, optionally ending in
  # `?`/`!`, not starting with a digit. This is deliberately the *narrow*
  # form (no unicode, no leading uppercase-only exceptions) — good enough to
  # write `:#{name}` safely and to read naturally in generated code; anything
  # outside it is rejected rather than quoted (simpler than juggling both
  # "quote if unusual" and "reject if unsafe" policies, and the acceptance
  # criteria for L6 accept rejection as a valid answer for unusual-but-benign
  # names too).
  @name ~r/^[A-Za-z_][A-Za-z0-9_]*[?!]?$/

  # A single Elixir alias segment: `Foo`, `FooBar2` — what `defmodule` and
  # `Macro.underscore/1` expect between dots.
  @alias_segment ~r/^[A-Z][A-Za-z0-9_]*$/

  @doc "Whether `value` is safe to splice as a bare atom identifier."
  @spec name?(term()) :: boolean()
  # `nil` is technically an atom (`:nil`), but accepting it here would let a
  # missing manifest field (rather than a deliberately-set one) render as
  # `:#{nil}` -> the empty, syntax-breaking `:` — treat it as invalid rather
  # than as a trusted literal.
  def name?(nil), do: false
  def name?(value) when is_atom(value), do: true
  def name?(value) when is_binary(value), do: Regex.match?(@name, value)
  def name?(_value), do: false

  @doc """
  Whether `value` is a safe dotted module alias — every segment a valid
  Elixir alias component. This is what guarantees `Macro.underscore/1` of the
  result never contains a `/`, `..`, or other character that could steer a
  generated file's path.
  """
  @spec module?(term()) :: boolean()
  def module?(value) when is_binary(value) and value != "" do
    value
    |> String.split(".")
    |> Enum.all?(&Regex.match?(@alias_segment, &1))
  end

  def module?(_value), do: false

  @doc "Validate a bare identifier, raising `AshRemote.Gen.InvalidManifestError` naming the offending field."
  @spec validate_name!(term(), String.t()) :: term()
  def validate_name!(value, context) do
    if name?(value) do
      value
    else
      raise InvalidManifestError,
        message:
          "manifest #{context} #{inspect(value)} is not a safe identifier — refusing to " <>
            "generate source that would splice it in unescaped"
    end
  end

  @doc "Validate a module alias, raising `AshRemote.Gen.InvalidManifestError` naming the offending field."
  @spec validate_module!(term(), String.t()) :: term()
  def validate_module!(value, context) do
    if module?(value) do
      value
    else
      raise InvalidManifestError,
        message:
          "manifest #{context} #{inspect(value)} is not a safe module name — refusing to " <>
            "generate a resource or file path from it"
    end
  end
end
