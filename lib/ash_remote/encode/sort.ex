defmodule AshRemote.Encode.Sort do
  @moduledoc """
  Encode an Ash sort (list of `{field, direction}`) into the wire `sort`
  list `AshRemote.Server`'s dispatch resolves (see its `resolve_sort/2`,
  which ultimately feeds `Ash.Query.sort_input/2`).

  Each entry is a plain string (`"field"`, `"-field"`, `"++field"`,
  `"--field"` — see `prefix/1` for the modifiers) UNLESS it is a
  PARAMETERIZED calculation (one with non-empty caller-supplied arguments),
  which instead becomes a map carrying its name, direction, and arguments —
  a bare string has nowhere to carry them. A legacy plain comma-joined
  string is still accepted server-side for backward compatibility, but this
  encoder always emits a list.
  """

  alias Ash.Query.Calculation

  @doc "Encode a sort list into a wire sort spec (a list), or `nil` when empty."
  def encode(nil), do: nil
  def encode([]), do: nil

  def encode(sort) when is_list(sort) do
    Enum.map(sort, &encode_one/1)
  end

  defp encode_one({field, direction}), do: encode_field(field, direction)
  defp encode_one(field) when is_atom(field), do: to_string(field)

  defp encode_field(%Calculation{} = calc, direction) do
    name = remote_calc_name(calc) || calc.calc_name || calc.name
    wire_calc_sort(name, calc_arguments(calc), direction)
  end

  defp encode_field(%{name: name}, direction), do: "#{prefix(direction)}#{name}"
  defp encode_field(field, direction) when is_atom(field), do: "#{prefix(direction)}#{field}"

  # Sorting on a calculation arrives as a hydrated `%Ash.Query.Calculation{}`
  # renamed to `:__calc__N` (ash/query/query.ex), but the original expression is
  # kept in `opts[:expr]`. A `remote(...)` proxied calc must be sorted on the
  # backend by its real name — pull it back out of the custom expression.
  defp remote_calc_name(%Calculation{opts: opts}) when is_list(opts) do
    case opts[:expr] do
      %Ash.CustomExpression{module: AshRemote.Expressions.Remote, arguments: [name | _]} ->
        name

      _ ->
        nil
    end
  end

  defp remote_calc_name(_), do: nil

  # L7-5: the caller-supplied arguments of a parameterized calc live in
  # `calc.context.arguments` — mirrors `AshRemote.Encode.Filter`'s
  # `calc_arguments/1`. They are NOT recoverable from the `remote/3` custom
  # expression's own static `arguments` list (`remote("name", %{"prefix" =>
  # arg(:prefix)}, pk)`): that's a TEMPLATE — `arg(:prefix)` is a reference
  # resolved against the calc's own context at evaluation time, not the
  # caller's actual value — so reading it directly would encode the
  # expression source, never the value the caller passed. This used to be
  # dropped entirely (only the calc NAME was pulled out), so the sort
  # silently evaluated with default/missing args instead of the caller's.
  defp calc_arguments(%Calculation{context: %{arguments: args}}) when is_map(args), do: args
  defp calc_arguments(_), do: %{}

  defp wire_calc_sort(name, args, direction) when args == %{} do
    "#{prefix(direction)}#{name}"
  end

  defp wire_calc_sort(name, args, direction) do
    %{
      "field" => to_string(name),
      "direction" => to_string(direction),
      "input" => Map.new(args, fn {k, v} -> {to_string(k), v} end)
    }
  end

  defp prefix(:asc), do: ""
  defp prefix(:asc_nils_last), do: ""
  defp prefix(:desc), do: "-"
  defp prefix(:desc_nils_first), do: "-"
  defp prefix(:asc_nils_first), do: "++"
  defp prefix(:desc_nils_last), do: "--"
end
