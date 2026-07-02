defmodule AshRemote.Encode.Filter do
  @moduledoc """
  Encode an `Ash.Filter` (or filter expression) into the wire `filter_input`
  map form the backend parses with `Ash.Query.filter_input/2`.

  Only the common operators (`==`, `!=`, `in`, `<`, `>`, `<=`, `>=`, `is_nil`) are
  encoded; anything else raises at build time.

  Optional gating: pass `:applicable` — a map of `field_name => [operator_name]`,
  intended to come from the manifest's per-field `filter_operators`. An operator not
  in a field's list raises a clear error. (Auto-populating `:applicable` from the
  embedded manifest capabilities is not yet wired — see the plan.)
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
  def encode(filter, opts \\ [])
  def encode(nil, _opts), do: nil
  def encode(%Ash.Filter{expression: nil}, _opts), do: nil
  def encode(%Ash.Filter{expression: expression}, opts), do: encode_expr(expression, opts)
  def encode(expression, opts), do: encode_expr(expression, opts)

  defp encode_expr(nil, _opts), do: nil
  defp encode_expr(true, _opts), do: %{}

  defp encode_expr(%BooleanExpression{op: op, left: left, right: right}, opts) do
    %{to_string(op) => [encode_expr(left, opts), encode_expr(right, opts)]}
  end

  defp encode_expr(%Not{expression: expression}, opts) do
    %{"not" => encode_expr(expression, opts)}
  end

  defp encode_expr(%mod{left: %Ref{} = ref, right: right}, opts) do
    predicate(mod, ref, right, opts)
  end

  # is_nil stores its boolean on `right` too; handled by the clause above.
  defp encode_expr(other, _opts) do
    raise ArgumentError,
          "AshRemote cannot encode filter expression #{inspect(other)} for the remote backend"
  end

  defp predicate(mod, ref, right, opts) do
    op = Map.get(@op_names, mod) || raise_unsupported(mod)
    field = ref_name(ref)
    gate!(field, op, opts)
    %{to_string(field) => %{op => value(right)}}
  end

  defp ref_name(%Ref{attribute: %{name: name}}), do: name
  defp ref_name(%Ref{attribute: name}) when is_atom(name), do: name

  defp value(%Ref{} = ref) do
    raise ArgumentError,
          "AshRemote cannot encode a field-to-field filter reference: #{inspect(ref)}"
  end

  defp value(%MapSet{} = set), do: MapSet.to_list(set)
  defp value(value), do: value

  defp gate!(_field, _op, opts) when opts == [], do: :ok

  defp gate!(field, op, opts) do
    case Keyword.get(opts, :applicable) do
      nil ->
        :ok

      applicable ->
        allowed = Map.get(applicable, field, [])

        unless op in allowed do
          raise ArgumentError,
                "operator #{inspect(op)} is not supported for field #{inspect(field)} " <>
                  "by the remote backend (allowed: #{inspect(allowed)})"
        end
    end
  end

  defp raise_unsupported(mod) do
    raise ArgumentError, "AshRemote cannot encode filter operator #{inspect(mod)}"
  end
end
