defmodule AshCloner.Sections do
  @moduledoc """
  The shared vocabulary of Ash resource DSL sections the cloner reconciles,
  plus the Sourceror/Igniter helpers for walking them.

  Both sides of the cloner speak this vocabulary: definition producers key
  their `entities:` maps by these section names, and the apply engine walks
  the corresponding DSL calls when ensuring entities and detecting drift.
  """

  @aggregate_calls [:count, :sum, :avg, :min, :max, :first, :list, :exists, :custom]

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
    aggregates: @aggregate_calls,
    actions: [:read, :create, :update, :destroy, :action]
  ]

  @doc "Section name → the DSL calls that declare a named entity in it."
  @spec section_calls() :: keyword([atom()])
  def section_calls, do: @section_calls

  @doc "The closed vocabulary of Ash aggregate kinds (as DSL call names)."
  @spec aggregate_calls() :: [atom()]
  def aggregate_calls, do: @aggregate_calls

  @doc "Move into the `do` block of a top-level section call, e.g. `attributes do`."
  @spec enter_section(Sourceror.Zipper.t(), atom()) :: {:ok, Sourceror.Zipper.t()} | :error
  def enter_section(zipper, section) do
    with {:ok, zipper} <-
           Igniter.Code.Function.move_to_function_call_in_current_scope(zipper, section, 1) do
      Igniter.Code.Common.move_to_do_block(zipper)
    end
  end

  @doc "The statements of a block the zipper points at (a single statement is its own list)."
  @spec statements(Sourceror.Zipper.t()) :: [Macro.t()]
  def statements(zipper) do
    case Sourceror.Zipper.node(zipper) do
      {:__block__, _, stmts} -> stmts
      stmt -> [stmt]
    end
  end

  @doc "The entity name an Ash DSL call declares (its first atom argument), or nil."
  @spec entity_name(Macro.t()) :: atom() | nil
  def entity_name({_call, _, [first | _]}) do
    case first do
      name when is_atom(name) -> name
      {:__block__, _, [name]} when is_atom(name) -> name
      _ -> nil
    end
  end

  def entity_name(_other), do: nil

  @doc """
  Definition equality modulo formatting: strip AST metadata (line numbers,
  parens, literal encodings) and compare.
  """
  @spec equivalent?(Macro.t(), Macro.t()) :: boolean()
  def equivalent?(left, right), do: strip_meta(left) == strip_meta(right)

  @doc "Strip all AST metadata, for formatting-insensitive comparison."
  @spec strip_meta(Macro.t()) :: Macro.t()
  def strip_meta(ast) do
    Macro.prewalk(ast, fn
      {name, _meta, args} -> {name, [], args}
      other -> other
    end)
  end
end
