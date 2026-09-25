defmodule AshCloner.Engine.Drift do
  @moduledoc false

  # After missing entities are ensured, an existing module can still disagree
  # with the definitions in two ways:
  #
  #   * :changed — an entity exists in both but is defined differently
  #     (a user edit, or the definition changed upstream)
  #   * :extra   — an entity exists in the file but not in the definitions
  #     (a user addition, or it was removed upstream)
  #
  # We can't tell which side is right, so nothing is done automatically:
  # by default each finding becomes a warning; with `interactive?` the user
  # decides per entity (keeping their version is always the default answer).
  #
  # `labels` (see `AshCloner.apply_definitions/3`) supplies the words for
  # "the definitions" and "upstream" so callers' warnings read naturally.
  #
  # Invariant shared with `AshCloner.Engine`: nothing here writes to the
  # filesystem — all changes go through the `Igniter.t()`.

  alias AshCloner.Engine
  alias AshCloner.Sections

  def reconcile(igniter, module, definition, interactive?, labels) do
    {igniter, drift} = detect_drift(igniter, module, definition)

    Enum.reduce(drift, igniter, fn finding, igniter ->
      cond do
        not interactive? ->
          Igniter.add_warning(igniter, warning(module, finding, labels))

        keep?(module, finding, labels) ->
          igniter

        finding.kind == :changed ->
          replace_entity(igniter, module, finding)

        finding.kind == :extra ->
          remove_entity(igniter, module, finding)
      end
    end)
  end

  defp detect_drift(igniter, module, %{kind: :resource, entities: entities}) do
    Spark.Igniter.find(igniter, module, fn _, zipper ->
      drift =
        Enum.flat_map(Sections.section_calls(), fn {section, calls} ->
          section_drift(zipper, section, calls, Map.fetch!(entities, section))
        end) ++ validations_drift(zipper, entities.validations)

      {:ok, drift}
    end)
    |> case do
      {:ok, igniter, _module, drift} -> {igniter, drift}
      {:error, igniter} -> {igniter, []}
    end
  end

  defp detect_drift(igniter, module, %{kind: :domain, resources: resources}) do
    expected = Enum.map(resources, &Igniter.Project.Module.parse/1)

    Spark.Igniter.find(igniter, module, fn _, zipper ->
      drift =
        with {:ok, zipper} <- Sections.enter_section(zipper, :resources) do
          zipper
          |> Sections.statements()
          |> Enum.flat_map(fn
            {:resource, _, [{:__aliases__, _, parts} | _]} = stmt ->
              if Module.concat(parts) in expected do
                []
              else
                [
                  %{
                    section: :resources,
                    name: Module.concat(parts),
                    kind: :extra,
                    current: Sourceror.to_string(stmt)
                  }
                ]
              end

            _ ->
              []
          end)
        else
          _ -> []
        end

      {:ok, drift}
    end)
    |> case do
      {:ok, igniter, _module, drift} -> {igniter, drift}
      {:error, igniter} -> {igniter, []}
    end
  end

  defp detect_drift(igniter, _module, %{kind: _other}), do: {igniter, []}

  # Validations are anonymous, so drift is judged by equivalence: any
  # `validate` in the file that matches no definition validation is extra.
  # (An edited one shows up as extra + the definition version re-added.)
  defp validations_drift(zipper, definition_entities) do
    targets =
      Enum.map(definition_entities, fn {_label, code} -> Sourceror.parse_string!(code) end)

    with {:ok, zipper} <- Sections.enter_section(zipper, :validations) do
      zipper
      |> Sections.statements()
      |> Enum.flat_map(fn
        {:validate, _, [_ | _]} = stmt ->
          if Enum.any?(targets, &Engine.same_validation?(stmt, &1)) do
            []
          else
            code = Sourceror.to_string(stmt)
            [%{section: :validations, name: code, kind: :extra, current: code}]
          end

        _ ->
          []
      end)
    else
      _ -> []
    end
  end

  defp section_drift(zipper, section, calls, definition_entities) do
    with {:ok, zipper} <- Sections.enter_section(zipper, section) do
      zipper
      |> Sections.statements()
      |> Enum.flat_map(fn stmt ->
        with {call, _, [_ | _]} <- stmt,
             true <- call in calls,
             name when not is_nil(name) <- Sections.entity_name(stmt) do
          entity_drift(section, name, stmt, List.keyfind(definition_entities, name, 0))
        else
          _ -> []
        end
      end)
    else
      _ -> []
    end
  end

  defp entity_drift(section, name, stmt, nil) do
    [%{section: section, name: name, kind: :extra, current: Sourceror.to_string(stmt)}]
  end

  defp entity_drift(section, name, stmt, {_name, definition_code}) do
    if Sections.equivalent?(stmt, Sourceror.parse_string!(definition_code)) do
      []
    else
      [
        %{
          section: section,
          name: name,
          kind: :changed,
          current: Sourceror.to_string(stmt),
          incoming: definition_code
        }
      ]
    end
  end

  # --- drift resolution ------------------------------------------------------

  defp keep?(module, %{kind: :changed} = finding, labels) do
    Igniter.Util.IO.yes?("""

    #{inspect(module)}: #{finding.section} entity #{inspect(finding.name)} differs from #{labels.definitions}.

    current:
    #{indent(finding.current)}

    #{labels.definitions}:
    #{indent(finding.incoming)}

    Keep the current version? (n replaces it with the version from #{labels.definitions})
    """)
  end

  defp keep?(module, %{section: :validations} = finding, labels) do
    Igniter.Util.IO.yes?("""

    #{inspect(module)}: a validation doesn't match any published by #{labels.definitions} —
    either you added or edited it, or it changed on #{labels.upstream}.

    #{indent(finding.current)}

    Keep it? (n removes it)
    """)
  end

  defp keep?(module, %{kind: :extra} = finding, labels) do
    Igniter.Util.IO.yes?("""

    #{inspect(module)}: #{finding.section} entity #{inspect(finding.name)} is not in #{labels.definitions} —
    either you added it, or it was removed on #{labels.upstream}.

    #{indent(finding.current)}

    Keep it? (n removes it)
    """)
  end

  defp warning(module, %{kind: :changed} = finding, labels) do
    "#{inspect(module)}: #{finding.section} entity #{inspect(finding.name)} differs from " <>
      "#{labels.definitions} (kept as-is — rerun with --interactive to resolve)"
  end

  defp warning(module, %{section: :validations} = finding, labels) do
    "#{inspect(module)}: validation `#{finding.current}` doesn't match any published by " <>
      "#{labels.definitions} — user-added/edited, or changed on #{labels.upstream} " <>
      "(kept as-is — rerun with --interactive to resolve)"
  end

  defp warning(module, %{kind: :extra} = finding, labels) do
    "#{inspect(module)}: #{finding.section} entity #{inspect(finding.name)} is not in " <>
      "#{labels.definitions} — user-added, or removed on #{labels.upstream} " <>
      "(kept as-is — rerun with --interactive to resolve)"
  end

  defp replace_entity(igniter, module, finding) do
    Igniter.Project.Module.find_and_update_module!(igniter, module, fn zipper ->
      with {:ok, zipper} <- Engine.move_to_entity(zipper, finding) do
        {:ok, Igniter.Code.Common.replace_code(zipper, finding.incoming)}
      end
    end)
  end

  defp remove_entity(igniter, module, finding) do
    Igniter.Project.Module.find_and_update_module!(igniter, module, fn zipper ->
      with {:ok, zipper} <- Engine.move_to_entity(zipper, finding) do
        {:ok, Sourceror.Zipper.remove(zipper)}
      end
    end)
  end

  defp indent(code) do
    code |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))
  end
end
