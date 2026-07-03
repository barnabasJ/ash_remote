defmodule AshRemote.Literal do
  @moduledoc """
  Round-trips option lists through Elixir source, for manifest entries that
  carry code (validation opts).

  `encode/1` inspects a term and verifies the result parses back into a *safe
  literal* — atoms, numbers, strings, lists, tuples, and maps, plus the one
  lazy call Spark embeds in DSL options: `{Spark.Regex, :cache, [source, flags]}`
  (how `~r/.../` is stored since OTP 28). Anything else — functions, arbitrary
  module/function references — fails to encode, which is what makes an option
  list "mirrorable": if it can't be written down as data, it isn't published.

  `safe?/1` runs the same check on already-received source (defense in depth on
  the consuming side, so a hand-crafted manifest can't inject code into
  generated resources).
  """

  @doc "Encode a term as Elixir source, or `:error` if it isn't a safe literal."
  def encode(term) do
    code = inspect(term, limit: :infinity, printable_limit: :infinity)
    if safe?(code), do: {:ok, code}, else: :error
  end

  @doc "Whether the given source parses into a safe literal."
  def safe?(code) when is_binary(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> safe_ast?(ast)
      _ -> false
    end
  end

  @doc "Evaluate source into a term, only if it's a safe literal."
  def eval(code) when is_binary(code) do
    if safe?(code) do
      {term, _binding} = Code.eval_string(code)
      {:ok, term}
    else
      :error
    end
  end

  defp safe_ast?(value)
       when is_atom(value) or is_number(value) or is_binary(value),
       do: true

  defp safe_ast?(list) when is_list(list), do: Enum.all?(list, &safe_ast?/1)

  # Spark stores DSL regexes as a lazy {Spark.Regex, :cache, [source, flags]}
  # call, applied at validate time — the ONLY tuple-of-three we allow. A
  # generic 3-tuple clause would let a crafted manifest smuggle an arbitrary
  # MFA (quoted atoms parse as plain atoms) into an option that gets applied.
  defp safe_ast?({:{}, _, [{:__aliases__, _, [:Spark, :Regex]}, :cache, args]}),
    do: safe_ast?(args)

  defp safe_ast?({:%{}, _, pairs}), do: Enum.all?(pairs, &safe_ast?/1)
  defp safe_ast?({left, right}), do: safe_ast?(left) and safe_ast?(right)
  defp safe_ast?(_), do: false
end
