defmodule AshCloner.Engine do
  @moduledoc false

  # Ensures a definition's entities exist on an already-existing module.
  #
  # Existing modules are never rewritten — the definitions' entities are
  # ensured by name and everything else (user additions and edits) is left
  # alone. Invariant shared with `AshCloner.Engine.Drift`: nothing here
  # writes to the filesystem — all changes go through the `Igniter.t()`, so
  # callers keep Igniter's `--dry-run`/`--check` semantics.

  alias AshCloner.Sections

  @aggregate_calls AshCloner.Sections.aggregate_calls()

  def ensure_entities(igniter, module, %{kind: :resource, entities: entities}) do
    igniter
    |> ensure_all(entities.attributes, module, &Ash.Resource.Igniter.add_new_attribute/4)
    |> ensure_all(entities.relationships, module, &Ash.Resource.Igniter.add_new_relationship/4)
    |> ensure_all(entities.validations, module, &add_new_validation/4)
    |> ensure_all(entities.calculations, module, &add_new_calculation/4)
    |> ensure_all(entities.aggregates, module, &add_new_aggregate/4)
    |> ensure_all(entities.actions, module, &Ash.Resource.Igniter.add_new_action/4)
  end

  # Not `Ash.Domain.Igniter.add_resource_reference/3`: its domain discovery
  # (app config + changed-source scan) doesn't reliably see our generated
  # domain and then "upgrades" it with a second `use Ash.Domain`. We know the
  # module is our domain, so ensure the reference directly.
  def ensure_entities(igniter, module, %{kind: :domain, resources: resources}) do
    Enum.reduce(resources, igniter, fn resource, igniter ->
      resource = Igniter.Project.Module.parse(resource)

      Igniter.Project.Module.find_and_update_module!(igniter, module, fn zipper ->
        case move_to_entity(zipper, %{section: :resources, name: resource}) do
          {:ok, _found} ->
            {:ok, zipper}

          :error ->
            case Sections.enter_section(zipper, :resources) do
              {:ok, section} ->
                {:ok, Igniter.Code.Common.add_code(section, "resource #{inspect(resource)}")}

              :error ->
                {:ok,
                 Igniter.Code.Common.add_code(
                   zipper,
                   "resources do\n  resource #{inspect(resource)}\nend"
                 )}
            end
        end
      end)
    end)
  end

  # Verbatim modules (named types, plain helpers…): nothing to reconcile
  # entity-wise — created whole once, then the file is the user's.
  def ensure_entities(igniter, _module, %{kind: _other}), do: igniter

  defp ensure_all(igniter, entities, module, add_new) do
    Enum.reduce(entities, igniter, fn {name, code}, igniter ->
      add_new.(igniter, module, name, code)
    end)
  end

  # `Ash.Resource.Igniter.defines_calculation/3` (through at least 3.29.3) only
  # matches `calculate` calls of arity 3, missing the `calculate ... do ... end`
  # form generated stubs use — so existing calculations would be re-added on
  # every regen. Same check with arity 3-or-4; candidate upstream fix.
  defp add_new_calculation(igniter, module, name, code) do
    {igniter, defines?} = defines_calculation(igniter, module, name)

    if defines? do
      igniter
    else
      Ash.Resource.Igniter.add_calculation(igniter, module, code)
    end
  end

  defp add_new_aggregate(igniter, module, name, code) do
    {igniter, defines?} = defines_aggregate(igniter, module, name)

    if defines? do
      igniter
    else
      Ash.Resource.Igniter.add_block(igniter, module, :aggregates, code)
    end
  end

  # An aggregate call (`count`, `sum`, …) for `name` already in the section.
  # Scanning statements (rather than `move_to_function_call_…`) lets us match on
  # any of the kind calls without threading igniter through each.
  defp defines_aggregate(igniter, module, name) do
    Spark.Igniter.find(igniter, module, fn _, zipper ->
      with {:ok, zipper} <- Sections.enter_section(zipper, :aggregates),
           true <- Enum.any?(Sections.statements(zipper), &aggregate_named?(&1, name)) do
        {:ok, true}
      else
        _ -> :error
      end
    end)
    |> case do
      {:ok, igniter, _module, _value} -> {igniter, true}
      {:error, igniter} -> {igniter, false}
    end
  end

  defp aggregate_named?({call, _, [_ | _]} = stmt, name)
       when call in @aggregate_calls,
       do: Sections.entity_name(stmt) == name

  defp aggregate_named?(_stmt, _name), do: false

  # Validations have no name to key on — identity is the definition itself.
  # One that matches a definition validation node-for-node already exists;
  # otherwise it's added.
  defp add_new_validation(igniter, module, _label, code) do
    {igniter, exists?} = has_equivalent_validation?(igniter, module, code)

    if exists? do
      igniter
    else
      Ash.Resource.Igniter.add_block(igniter, module, :validations, code)
    end
  end

  defp has_equivalent_validation?(igniter, module, code) do
    target = Sourceror.parse_string!(code)

    Spark.Igniter.find(igniter, module, fn _, zipper ->
      with {:ok, zipper} <- Sections.enter_section(zipper, :validations),
           true <- Enum.any?(Sections.statements(zipper), &same_validation?(&1, target)) do
        {:ok, true}
      else
        _ -> :error
      end
    end)
    |> case do
      {:ok, igniter, _module, _value} -> {igniter, true}
      {:error, igniter} -> {igniter, false}
    end
  end

  # Validations compare by meaning, not text: `string_length(:title, min: 3)`
  # equals `{Ash.Resource.Validation.StringLength, [min: 3, attribute: :title]}`
  # whatever the option order. Plain AST equality is the fallback when a
  # statement can't be safely evaluated.
  @doc false
  def same_validation?(stmt, target) do
    case {AshCloner.Validations.identity(stmt), AshCloner.Validations.identity(target)} do
      {{:ok, left}, {:ok, right}} -> left == right
      _ -> Sections.strip_meta(stmt) == Sections.strip_meta(target)
    end
  end

  defp defines_calculation(igniter, module, name) do
    Spark.Igniter.find(igniter, module, fn _, zipper ->
      with {:ok, zipper} <-
             Igniter.Code.Function.move_to_function_call_in_current_scope(
               zipper,
               :calculations,
               1
             ),
           {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper),
           {:ok, _zipper} <-
             Igniter.Code.Function.move_to_function_call_in_current_scope(
               zipper,
               :calculate,
               [3, 4],
               &Igniter.Code.Function.argument_equals?(&1, 0, name)
             ) do
        {:ok, true}
      else
        _ -> :error
      end
    end)
    |> case do
      {:ok, igniter, _module, _value} -> {igniter, true}
      {:error, igniter} -> {igniter, false}
    end
  end

  # --- entity addressing (shared with Drift) ---------------------------------

  @doc false
  def move_to_entity(zipper, %{section: :validations, current: current}) do
    target = Sourceror.parse_string!(current)

    with {:ok, zipper} <- Sections.enter_section(zipper, :validations) do
      case Sourceror.Zipper.node(zipper) do
        {:__block__, _, _} ->
          zipper |> Sourceror.Zipper.down() |> find_sibling(target)

        node ->
          if same_validation?(node, target), do: {:ok, zipper}, else: :error
      end
    end
  end

  def move_to_entity(zipper, %{section: :resources, name: module}) do
    with {:ok, zipper} <- Sections.enter_section(zipper, :resources) do
      Igniter.Code.Function.move_to_function_call_in_current_scope(
        zipper,
        :resource,
        [1, 2],
        &Igniter.Code.Function.argument_equals?(&1, 0, module)
      )
    end
  end

  def move_to_entity(zipper, %{section: section, name: name}) do
    calls = Keyword.fetch!(Sections.section_calls(), section)

    with {:ok, zipper} <- Sections.enter_section(zipper, section) do
      Enum.reduce_while(calls, :error, fn call, _acc ->
        case Igniter.Code.Function.move_to_function_call_in_current_scope(
               zipper,
               call,
               [1, 2, 3, 4],
               &Igniter.Code.Function.argument_equals?(&1, 0, name)
             ) do
          {:ok, zipper} -> {:halt, {:ok, zipper}}
          :error -> {:cont, :error}
        end
      end)
    end
  end

  defp find_sibling(nil, _target), do: :error

  defp find_sibling(zipper, target) do
    if same_validation?(Sourceror.Zipper.node(zipper), target) do
      {:ok, zipper}
    else
      zipper |> Sourceror.Zipper.right() |> find_sibling(target)
    end
  end
end
