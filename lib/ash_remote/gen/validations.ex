defmodule AshRemote.Gen.Validations do
  @moduledoc """
  Sugar rendering and form-insensitive identity for mirrored validations.

  Validations exist in two spellings: the `Ash.Resource.Validation.Builtins`
  sugar people write (`string_length(:title, min: 3)`) and the `{Module, opts}`
  tuple it expands to. `sugar/2` renders the manifest's tuple back into the
  sugar — but only when *calling the builtin actually reproduces the opts*,
  so the rendering can never be lossy. `identity/1` canonicalizes a `validate`
  statement's AST (either spelling, any option order, `~r//` or Spark's lazy
  regex tuple) so regeneration and drift detection compare meaning, not text.
  """

  alias Ash.Resource.Validation.Builtins

  @builtin_functions Builtins.__info__(:functions) |> Keyword.keys() |> Enum.uniq()

  # --- sugar rendering -------------------------------------------------------

  @doc "Render `{module, opts}` as its Builtins call, when exactly equivalent."
  def sugar(module_string, opts) when is_binary(module_string) and is_list(opts) do
    module = Module.concat([module_string])

    with {:ok, {fun, args}} <- sugar_candidate(module, opts),
         true <- verified?(fun, args, module, opts) do
      {:ok, render_call(fun, args)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp sugar_candidate(module, opts) do
    alias Ash.Resource.Validation, as: V

    case module do
      V.StringLength -> attribute_and_rest(:string_length, opts)
      V.ByteSize -> attribute_and_rest(:byte_size, opts)
      V.Compare -> attribute_and_rest(:compare, opts)
      V.Match -> {:ok, {:match, [opts[:attribute], regex(opts[:match])]}}
      V.OneOf -> {:ok, {:one_of, [opts[:attribute], opts[:values]]}}
      V.Present -> attributes_and_rest(:present, opts)
      V.AttributesPresent -> attributes_and_rest(:attributes_present, opts)
      V.Changing -> {:ok, {:changing, [opts[:field]]}}
      V.ActionIs -> {:ok, {:action_is, [opts[:action]]}}
      V.AttributeEquals -> {:ok, {:attribute_equals, [opts[:attribute], opts[:value]]}}
      V.AttributeDoesNotEqual -> {:ok, {:attribute_does_not_equal, [opts[:attribute], opts[:value]]}}
      V.ArgumentEquals -> {:ok, {:argument_equals, [opts[:argument], opts[:value]]}}
      V.ArgumentDoesNotEqual -> {:ok, {:argument_does_not_equal, [opts[:argument], opts[:value]]}}
      V.ArgumentIn -> {:ok, {:argument_in, [opts[:argument], opts[:list]]}}
      V.Confirm -> {:ok, {:confirm, [opts[:field], opts[:confirmation]]}}
      _ -> :error
    end
  end

  defp attribute_and_rest(fun, opts) do
    {:ok, {fun, [opts[:attribute], Keyword.delete(opts, :attribute)]}}
  end

  defp attributes_and_rest(fun, opts) do
    attributes =
      case opts[:attributes] do
        [single] -> single
        many -> many
      end

    {:ok, {fun, [attributes, Keyword.delete(opts, :attributes)]}}
  end

  # The check that keeps sugar honest: the rendered call, executed, must
  # produce the exact opts the manifest published.
  defp verified?(fun, args, module, opts) do
    args = Enum.reject(args, &(&1 == []))

    case apply(Builtins, fun, args) do
      {^module, produced} -> canonical(produced) == canonical(opts)
      _ -> false
    end
  end

  defp render_call(fun, args) do
    args =
      args
      |> Enum.reject(&(&1 == []))
      |> Enum.map_join(", ", &render_arg/1)

    "#{fun}(#{args})"
  end

  # A trailing keyword list renders without brackets, like a person writes it.
  defp render_arg(arg) do
    if Keyword.keyword?(arg) and arg != [] do
      arg |> inspect() |> String.slice(1..-2//1)
    else
      inspect(render_regexes(arg))
    end
  end

  defp render_regexes({Spark.Regex, :cache, [source, flags]}),
    do: Regex.compile!(source, flags_string(flags))

  defp render_regexes(other), do: other

  defp regex({Spark.Regex, :cache, [source, flags]}), do: Regex.compile!(source, flags_string(flags))
  defp regex(other), do: other

  defp flags_string(flags) when is_binary(flags), do: flags
  defp flags_string(flags) when is_list(flags), do: to_string(flags)

  # --- form-insensitive identity ---------------------------------------------

  @doc """
  Canonical identity of a `validate` statement's AST, or `:error` when it
  can't be safely evaluated (then callers fall back to plain AST comparison).
  """
  def identity({:validate, _, [_ | _] = args}) do
    source = Enum.map_join(args, ", ", &Sourceror.to_string/1)

    with {:ok, ast} <- Code.string_to_quoted("[#{source}]"),
         true <- safe_validation_ast?(ast) do
      {[ref | rest], _} =
        Code.eval_string("import Ash.Resource.Validation.Builtins, warn: false\n[#{source}]")

      # `validate ref, [on: ...]` (explicit brackets) evaluates to a nested
      # list; `validate ref, on: ...` to trailing tuples — normalize both.
      rest = if match?([opts] when is_list(opts), rest), do: List.first(rest), else: rest

      with {module, opts} when is_atom(module) and is_list(opts) <- ref,
           true <- validation_module?(module),
           {:ok, where} <- identity_where(Keyword.get(rest, :where, [])) do
        {:ok,
         %{
           module: module,
           opts: canonical(opts),
           on: rest |> Keyword.get(:on, [:create, :update]) |> Enum.sort(),
           where: where,
           message: Keyword.get(rest, :message),
           only_when_valid?: Keyword.get(rest, :only_when_valid?, false)
         }}
      else
        _ -> :error
      end
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def identity(_other), do: :error

  defp identity_where(conditions) when is_list(conditions) do
    conditions
    |> Enum.reduce_while([], fn
      {module, opts}, acc when is_atom(module) and is_list(opts) ->
        if validation_module?(module) do
          {:cont, [{module, canonical(opts)} | acc]}
        else
          {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      :error -> :error
      acc -> {:ok, Enum.sort(acc)}
    end
  end

  defp identity_where(_), do: :error

  defp validation_module?(module) do
    String.starts_with?(Atom.to_string(module), "Elixir.Ash.Resource.Validation.")
  end

  # Only literals, Builtins calls, and ~r sigils may be evaluated.
  defp safe_validation_ast?(value)
       when is_atom(value) or is_number(value) or is_binary(value),
       do: true

  defp safe_validation_ast?(list) when is_list(list),
    do: Enum.all?(list, &safe_validation_ast?/1)

  defp safe_validation_ast?({:__aliases__, _, parts}) when is_list(parts), do: true

  defp safe_validation_ast?({:sigil_r, _, args}), do: safe_validation_ast?(args)

  defp safe_validation_ast?({:{}, _, elements}), do: Enum.all?(elements, &safe_validation_ast?/1)
  defp safe_validation_ast?({:%{}, _, pairs}), do: Enum.all?(pairs, &safe_validation_ast?/1)

  defp safe_validation_ast?({fun, _, args}) when fun in @builtin_functions and is_list(args),
    do: Enum.all?(args, &safe_validation_ast?/1)

  defp safe_validation_ast?({left, right}),
    do: safe_validation_ast?(left) and safe_validation_ast?(right)

  defp safe_validation_ast?(_), do: false

  # Meaning-level equality: option order doesn't matter, and a compiled
  # `~r//` equals Spark's lazy regex tuple for the same source/flags.
  defp canonical({Spark.Regex, :cache, [source, flags]}), do: {:regex, source, flags_string(flags)}
  defp canonical(%Regex{} = regex), do: {:regex, Regex.source(regex), to_string(Regex.opts(regex))}

  defp canonical(list) when is_list(list) do
    if Keyword.keyword?(list) do
      list |> Enum.map(fn {key, value} -> {key, canonical(value)} end) |> Enum.sort()
    else
      Enum.map(list, &canonical/1)
    end
  end

  defp canonical({left, right}), do: {canonical(left), canonical(right)}
  defp canonical(other), do: other
end
