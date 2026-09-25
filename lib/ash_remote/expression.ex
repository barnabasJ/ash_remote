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
    * `if`/`cond` — `cond do ... end` desugars to nested `Ash.Query.Function.If`
      calls; each branch's condition and both outcomes are walked recursively
    * the zero-argument time functions `today()` / `now()`
    * literals that survive `AshRemote.Literal`-style checks, plus date/time
      sigils

  Anything else — relationship refs, fragments, arbitrary functions,
  parameterized calculations — fails to encode: if it can't be written down
  as data, it isn't published, and the server stays authoritative. This
  deliberately excludes functions like `lower/1`/`upper/1` on a Postgres
  range even though they look like plain single-argument calls: they compile
  to a raw Postgres SQL function with no defined meaning on another data
  layer (unlike `Ash.Query.Function.If`, which has a real data-layer-agnostic
  `evaluate/1`) — mirroring them by name alone would silently collide with
  SQLite's own `lower`/`upper` string-casing builtins on the client and
  return wrong values instead of failing loudly, so they stay `remote(...)`.

  A referenced name may be a public attribute, aggregate, *or* calculation on
  `resource` — not attributes alone. This module only gates *publish-time*
  safety (is the name public, is the shape data-expressible); it does not
  and cannot know whether any given downstream client will actually mirror
  that particular aggregate/calculation locally. That reproducibility check
  is a separate, client-side concern — see `AshRemote.Gen`'s
  `calculation_block/4`, which re-verifies every name `referenced_names/1`
  reports against the fields *this* generation run actually emits before
  trusting a manifest-provided expression, falling back to `remote(...)`
  for the whole calculation if any referenced name doesn't check out.

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
  node falls outside the safe set. `resource` scopes the public-field check
  (attribute, aggregate, or calculation).
  """
  @spec encode(term(), Ash.Resource.t()) :: {:ok, String.t()} | :error
  def encode(expression, resource) do
    case walk(expression, resource) do
      {:ok, code} -> if safe?(code), do: {:ok, code}, else: :error
      :error -> :error
    end
  end

  defp public_field?(resource, name) do
    Ash.Resource.Info.public_attribute(resource, name) != nil ||
      Ash.Resource.Info.public_aggregate(resource, name) != nil ||
      Ash.Resource.Info.public_calculation(resource, name) != nil
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

  # `cond do A -> x; B -> y; true -> z end` desugars to nested
  # `Ash.Query.Call{name: :if, args: [condition, [do: ..., else: ...]]}` at
  # this unhydrated-template stage — see `Ash.Query.Function.If.new/2`. Each
  # branch's condition and both outcomes (which may themselves be a nested
  # `if`, an attribute ref, or a literal) are walked recursively.
  defp walk(
         %Ash.Query.Call{relationship_path: [], name: :if, args: [condition, opts]},
         resource
       )
       when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, cond_code} <- walk(condition, resource),
         {:ok, do_code} <- walk(Keyword.get(opts, :do), resource),
         {:ok, else_code} <- walk(Keyword.get(opts, :else), resource) do
      {:ok, "if(#{cond_code}, do: #{do_code}, else: #{else_code})"}
    else
      _ -> :error
    end
  end

  # The already-hydrated `Ash.Query.Function.If{arguments: [...]}` shape
  # (positional condition/when_true/when_false, no keyword-list block) —
  # nested branches can arrive this way once an outer `if` has already been
  # processed by `Ash.Query.Function.If.new/1`.
  defp walk(%Ash.Query.Function.If{arguments: [condition, when_true, when_false]}, resource) do
    with {:ok, cond_code} <- walk(condition, resource),
         {:ok, true_code} <- walk(when_true, resource),
         {:ok, false_code} <- walk(when_false, resource) do
      {:ok, "if(#{cond_code}, do: #{true_code}, else: #{false_code})"}
    end
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

    if name && public_field?(resource, name) do
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
  def safe?(code) when is_binary(code), do: match?({:ok, _names}, parse(code))

  @doc """
  The bare-variable (attribute/aggregate/calculation) names referenced by
  already-`safe?/1` source, or `:error` if the source doesn't parse into the
  safe grammar at all. This is `AshRemote.Gen`'s hook for the client-side
  reproducibility check `encode/2`'s own moduledoc describes: knowing a
  manifest expression is *safe to have been published* says nothing about
  whether *this particular generation run* will actually emit every field
  it depends on — the generator re-resolves each name returned here against
  the fields it's about to emit before trusting the expression.
  """
  @spec referenced_names(String.t()) :: {:ok, [atom()]} | :error
  def referenced_names(code) when is_binary(code), do: parse(code)

  # Single walk shared by `safe?/1` and `referenced_names/1` so the two can
  # never drift apart on what grammar they accept — `safe?/1` used to be a
  # separate boolean-returning traversal (`safe_ast?/1`) duplicating this
  # exact structure, which is precisely the kind of two-copies-to-keep-in-sync
  # this module's own doc warns generated code against.
  defp parse(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> safe_names(ast)
      _ -> :error
    end
  end

  defp safe_names({op, _, [left, right]})
       when op in [:and, :or, :==, :!=, :<, :<=, :>, :>=, :in] do
    with {:ok, l} <- safe_names(left), {:ok, r} <- safe_names(right), do: {:ok, l ++ r}
  end

  defp safe_names({:not, _, [inner]}), do: safe_names(inner)
  defp safe_names({:is_nil, _, [inner]}), do: safe_names(inner)
  defp safe_names({function, _, []}) when function in [:today, :now], do: {:ok, []}

  defp safe_names({:if, _, [condition, opts]}) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, c} <- safe_names(condition),
         {:ok, d} <- safe_names(Keyword.get(opts, :do)),
         {:ok, e} <- safe_names(Keyword.get(opts, :else)) do
      {:ok, c ++ d ++ e}
    else
      _ -> :error
    end
  end

  # A bare variable is an attribute/aggregate/calculation reference.
  defp safe_names({name, _, context}) when is_atom(name) and is_atom(context), do: {:ok, [name]}
  defp safe_names(other), do: if(literal_ast?(other), do: {:ok, []}, else: :error)

  defp literal_code?(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> literal_ast?(ast)
      _ -> false
    end
  end

  defp literal_ast?(value) when is_atom(value) or is_number(value) or is_binary(value), do: true
  defp literal_ast?(list) when is_list(list), do: Enum.all?(list, &literal_ast?/1)

  defp literal_ast?({sigil, _, [{:<<>>, _, [string]}, modifiers]})
       when sigil in [:sigil_D, :sigil_T, :sigil_U, :sigil_N] and is_binary(string) and
              is_list(modifiers),
       do: true

  defp literal_ast?(_), do: false
end
