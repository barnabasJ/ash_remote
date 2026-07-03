defmodule AshRemote.Expression do
  @moduledoc """
  Round-trips calculation expressions through Elixir source, for manifest
  entries that mirror server-side expression calculations onto generated
  client resources (the calculation counterpart of `AshRemote.Literal`).

  `encode/2` walks a stored expression AST (the struct tree Ash keeps for
  `Ash.Resource.Calculation.Expression`) and emits `expr(...)`-compatible
  source **only if every node is in a safe, data-expressible set**:

    * references to the resource's own public attributes (no relationship
      paths)
    * operators `==`, `!=`, `in`, `<`, `<=`, `>`, `>=`, `is_nil`
    * `and` / `or` / `not`
    * the zero-argument time functions `today()` / `now()`
    * literals that survive `AshRemote.Literal`-style checks, plus date/time
      sigils

  Anything else — relationship refs, fragments, arbitrary functions,
  parameterized calculations — fails to encode: if it can't be written down
  as data, it isn't published, and the server stays authoritative.

  `safe?/1` validates already-received source on the consuming side, so a
  hand-crafted manifest cannot inject code into generated resources.
  """

  alias Ash.Query.{BooleanExpression, Not, Ref}

  @operators %{
    Ash.Query.Operator.Eq => "==",
    Ash.Query.Operator.NotEq => "!=",
    Ash.Query.Operator.In => "in",
    Ash.Query.Operator.LessThan => "<",
    Ash.Query.Operator.LessThanOrEqual => "<=",
    Ash.Query.Operator.GreaterThan => ">",
    Ash.Query.Operator.GreaterThanOrEqual => ">="
  }

  @functions %{
    Ash.Query.Function.Today => "today",
    Ash.Query.Function.Now => "now"
  }

  @doc """
  Encode a stored expression as `expr(...)` source, or `:error` when any
  node falls outside the safe set. `resource` scopes the public-attribute
  check.
  """
  @spec encode(term(), Ash.Resource.t()) :: {:ok, String.t()} | :error
  def encode(expression, resource) do
    case walk(expression, resource) do
      {:ok, code} -> if safe?(code), do: {:ok, code}, else: :error
      :error -> :error
    end
  end

  defp walk(%BooleanExpression{op: op, left: left, right: right}, resource)
       when op in [:and, :or] do
    with {:ok, left_code} <- walk(left, resource),
         {:ok, right_code} <- walk(right, resource) do
      {:ok, "(#{left_code} #{op} #{right_code})"}
    end
  end

  defp walk(%Not{expression: expression}, resource) do
    with {:ok, code} <- walk(expression, resource) do
      {:ok, "not (#{code})"}
    end
  end

  # Stored calculation expressions are unhydrated templates: operators and
  # functions appear as %Ash.Query.Call{} nodes rather than operator structs.
  @call_operators [:==, :!=, :<, :<=, :>, :>=, :in, :and, :or]

  defp walk(%Ash.Query.Call{relationship_path: [], name: name, args: [left, right]}, resource)
       when name in @call_operators do
    with {:ok, left_code} <- walk(left, resource),
         {:ok, right_code} <- walk(right, resource) do
      {:ok, "(#{left_code} #{name} #{right_code})"}
    end
  end

  defp walk(%Ash.Query.Call{relationship_path: [], name: :not, args: [inner]}, resource) do
    with {:ok, code} <- walk(inner, resource) do
      {:ok, "not (#{code})"}
    end
  end

  defp walk(%Ash.Query.Call{relationship_path: [], name: :is_nil, args: [inner]}, resource) do
    with {:ok, code} <- walk(inner, resource) do
      {:ok, "is_nil(#{code})"}
    end
  end

  defp walk(%Ash.Query.Call{relationship_path: [], name: function, args: []}, _resource)
       when function in [:today, :now] do
    {:ok, "#{function}()"}
  end

  defp walk(%Ash.Query.Call{}, _resource), do: :error

  defp walk(%Ash.Query.Operator.IsNil{left: left, right: right}, resource) do
    with {:ok, ref_code} <- walk(left, resource),
         true <- is_boolean(right) do
      if right, do: {:ok, "is_nil(#{ref_code})"}, else: {:ok, "not is_nil(#{ref_code})"}
    else
      _ -> :error
    end
  end

  defp walk(%struct{left: left, right: right}, resource) when is_map_key(@operators, struct) do
    with {:ok, left_code} <- walk(left, resource),
         {:ok, right_code} <- walk(right, resource) do
      {:ok, "(#{left_code} #{Map.fetch!(@operators, struct)} #{right_code})"}
    end
  end

  defp walk(%struct{arguments: []}, _resource) when is_map_key(@functions, struct) do
    {:ok, "#{Map.fetch!(@functions, struct)}()"}
  end

  defp walk(%Ref{relationship_path: [], attribute: attribute}, resource) do
    name =
      case attribute do
        %{name: name} -> name
        name when is_atom(name) -> name
        _ -> nil
      end

    if name && Ash.Resource.Info.public_attribute(resource, name) do
      {:ok, to_string(name)}
    else
      :error
    end
  end

  defp walk(%MapSet{} = values, resource), do: walk(MapSet.to_list(values), resource)

  defp walk(values, resource) when is_list(values) do
    values
    |> Enum.reduce_while([], fn value, acc ->
      case walk(value, resource) do
        {:ok, code} -> {:cont, [code | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      codes -> {:ok, "[#{codes |> Enum.reverse() |> Enum.join(", ")}]"}
    end
  end

  defp walk(value, _resource) do
    # Literals. Structs that are query AST nodes were matched above; any
    # remaining struct must inspect to a safe sigil/literal form.
    code = inspect(value, limit: :infinity, printable_limit: :infinity)
    if literal_code?(code), do: {:ok, code}, else: :error
  end

  @doc "Whether the source parses into the safe expression grammar."
  @spec safe?(String.t()) :: boolean()
  def safe?(code) when is_binary(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> safe_ast?(ast)
      _ -> false
    end
  end

  defp literal_code?(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> literal_ast?(ast)
      _ -> false
    end
  end

  defp safe_ast?({op, _, [left, right]}) when op in [:and, :or, :==, :!=, :<, :<=, :>, :>=, :in],
    do: safe_ast?(left) and safe_ast?(right)

  defp safe_ast?({:not, _, [inner]}), do: safe_ast?(inner)
  defp safe_ast?({:is_nil, _, [inner]}), do: safe_ast?(inner)
  defp safe_ast?({function, _, []}) when function in [:today, :now], do: true
  # A bare variable is an attribute reference.
  defp safe_ast?({name, _, context}) when is_atom(name) and is_atom(context), do: true
  defp safe_ast?(other), do: literal_ast?(other)

  defp literal_ast?(value) when is_atom(value) or is_number(value) or is_binary(value), do: true
  defp literal_ast?(list) when is_list(list), do: Enum.all?(list, &literal_ast?/1)

  defp literal_ast?({sigil, _, [{:<<>>, _, [string]}, modifiers]})
       when sigil in [:sigil_D, :sigil_T, :sigil_U, :sigil_N] and is_binary(string) and
              is_list(modifiers),
       do: true

  defp literal_ast?(_), do: false
end
