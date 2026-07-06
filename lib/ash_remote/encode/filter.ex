defmodule AshRemote.Encode.Filter do
  @moduledoc """
  Encode an `Ash.Filter` (or filter expression) into the wire `filter_input`
  map form the backend parses with `Ash.Query.filter_input/2`.

  Only the common operators (`==`, `!=`, `in`, `<`, `>`, `<=`, `>=`, `is_nil`) are
  encoded; anything else raises at build time.

  R-10: this used to accept an `:applicable` gate (a map of
  `field_name => [operator_name]`), but `remote_config/1` never actually
  populated it — `applicable: nil` unconditionally, on every call site — so
  the gate was permanently a no-op. Deleted rather than wired up: the server
  remains the real authority on which operators a field supports, and the
  manifest data this would have gated on still survives in the loader's
  normalized `filter_operators` for a future re-introduction (which would
  also need to extend the generator, since it doesn't currently emit
  per-field operator info at all).
  """

  alias Ash.Query.{BooleanExpression, Not, Ref}

  @op_names %{
    Ash.Query.Operator.Eq => "eq",
    Ash.Query.Operator.NotEq => "not_eq",
    Ash.Query.Operator.In => "in",
    Ash.Query.Operator.LessThan => "less_than",
    Ash.Query.Operator.GreaterThan => "greater_than",
    Ash.Query.Operator.LessThanOrEqual => "less_than_or_equal",
    Ash.Query.Operator.GreaterThanOrEqual => "greater_than_or_equal",
    Ash.Query.Operator.IsNil => "is_nil"
  }

  @doc "Encode a filter into a wire map, or `nil` when there is no filter."
  def encode(filter)
  def encode(nil), do: nil
  def encode(%Ash.Filter{expression: nil}), do: nil
  def encode(%Ash.Filter{expression: expression}), do: encode_expr(expression)
  def encode(expression), do: encode_expr(expression)

  defp encode_expr(nil), do: nil
  defp encode_expr(true), do: %{}

  defp encode_expr(%BooleanExpression{op: op, left: left, right: right}) do
    %{to_string(op) => [encode_expr(left), encode_expr(right)]}
  end

  defp encode_expr(%Not{expression: expression}) do
    %{"not" => encode_expr(expression)}
  end

  defp encode_expr(%mod{left: %Ref{} = ref, right: right}) do
    predicate(mod, ref, right)
  end

  # is_nil stores its boolean on `right` too; handled by the clause above.
  defp encode_expr(other) do
    raise ArgumentError,
          "AshRemote cannot encode filter expression #{inspect(other)} for the remote backend"
  end

  defp predicate(mod, ref, right) do
    op = Map.get(@op_names, mod) || raise_unsupported(mod)
    field = ref_name(ref)

    # A parameterized calculation carries its arguments; the backend's
    # `filter_input` reads them from an `"input"` key alongside the operator.
    predicate = %{op => value(right)}
    predicate = maybe_put_input(predicate, ref)
    %{to_string(field) => predicate}
  end

  defp maybe_put_input(predicate, %Ref{attribute: %Ash.Query.Calculation{} = calc}) do
    case calc_arguments(calc) do
      args when args == %{} -> predicate
      args -> Map.put(predicate, "input", stringify_keys(args))
    end
  end

  defp maybe_put_input(predicate, _ref), do: predicate

  defp calc_arguments(%Ash.Query.Calculation{context: %{arguments: args}}) when is_map(args),
    do: args

  defp calc_arguments(_), do: %{}

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp ref_name(%Ref{attribute: %{name: name}}), do: name
  defp ref_name(%Ref{attribute: name}) when is_atom(name), do: name

  defp value(%Ref{} = ref) do
    raise ArgumentError,
          "AshRemote cannot encode a field-to-field filter reference: #{inspect(ref)}"
  end

  defp value(%MapSet{} = set), do: MapSet.to_list(set)
  defp value(value), do: value

  defp raise_unsupported(mod) do
    raise ArgumentError, "AshRemote cannot encode filter operator #{inspect(mod)}"
  end
end
