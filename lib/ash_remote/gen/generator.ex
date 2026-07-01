defmodule AshRemote.Gen do
  @moduledoc """
  Turns an `AshRemote.Manifest` into standalone Ash resource source code.

  `generate/2` returns a list of `{module_name_string, source_string}`:

    * one module per named type (`Ash.Type.Enum` / `Ash.Type.NewType`)
    * one module per resource (attributes, relationships, calc/aggregate stubs,
      action stubs, and a `remote` block), backed by `AshRemote.DataLayer`
    * a client domain listing the resources

  Backend module names are re-namespaced under `:namespace` by stripping the
  longest common prefix. Aggregates and calculations are both emitted as
  loadable calculation stubs — the backend computes their values; the stub's
  placeholder expression is non-constant (so Ash routes it through the data
  layer) and its type is irrelevant (the data layer overwrites it).
  """

  alias AshRemote.Manifest

  @doc "Generate `[{module_string, source_string}]` from a manifest."
  def generate(%Manifest{} = manifest, opts) do
    namespace = Keyword.fetch!(opts, :namespace)
    domain = opts[:domain] || namespace <> ".Domain"

    # Drop builtin Ash types (e.g. Ash.Type.UtcDatetimeUsec from a timestamp) —
    # only custom named types (enums, NewTypes) get their own generated module.
    custom_types =
      manifest.types |> Enum.reject(fn {module, _} -> builtin_type?(module) end) |> Map.new()

    modules = Map.keys(manifest.resources) ++ Map.keys(custom_types)
    prefix = common_prefix(modules)

    ctx = %{
      namespace: namespace,
      prefix: prefix,
      domain: domain,
      base_url: opts[:base_url],
      manifest: manifest,
      types: custom_types
    }

    types = Enum.map(custom_types, fn {_m, type} -> gen_type(type, ctx) end)
    resources = Enum.map(manifest.resources, fn {_m, res} -> gen_resource(res, ctx) end)

    types ++ resources ++ [gen_domain(ctx)]
  end

  # --- types ---------------------------------------------------------------

  defp gen_type(type, ctx) do
    module = client_module(type.module, ctx)

    body =
      case type.kind do
        :enum ->
          values = Enum.map_join(type.values, ", ", &":#{&1}")
          "  use Ash.Type.Enum, values: [#{values}]"

        subtype ->
          "  use Ash.Type.NewType, subtype_of: #{inspect(subtype)}"
      end

    {module, "defmodule #{module} do\n#{body}\nend\n"}
  end

  # --- resources -----------------------------------------------------------

  defp gen_resource(res, ctx) do
    module = client_module(res.module, ctx)
    fk_names = belongs_to_fks(res)

    attributes = gen_attributes(res, fk_names, ctx)
    relationships = gen_relationships(res, ctx)
    calculations = gen_calculations(res, ctx)
    actions = gen_actions(res)
    remote = gen_remote(res, ctx)

    source =
      """
      defmodule #{module} do
        use Ash.Resource,
          domain: #{ctx.domain},
          data_layer: AshRemote.DataLayer,
          extensions: [AshRemote.Resource]

      #{remote}

      #{attributes}
      #{relationships}#{calculations}
      #{actions}
      end
      """

    {module, source}
  end

  defp gen_remote(res, ctx) do
    managed_attrs = manifest_attribute_names(res) -- belongs_to_fks(res)
    managed_calcs = manifest_loadable_names(res)
    managed_rels = Map.keys(res.relationships) |> Enum.map(&String.to_atom/1)
    managed_actions = Enum.map(res.actions, &String.to_atom(&1.name))

    base =
      if ctx.base_url, do: "    base_url #{inspect(ctx.base_url)}\n", else: ""

    """
      remote do
        source #{inspect(res.module)}
        schema_version #{inspect(ctx.manifest.schema_version)}
    #{base}    managed_attributes #{inspect(managed_attrs)}
        managed_relationships #{inspect(managed_rels)}
        managed_calculations #{inspect(managed_calcs)}
        managed_actions #{inspect(managed_actions)}
      end
    """
    |> String.trim_trailing()
  end

  defp gen_attributes(res, fk_names, ctx) do
    lines =
      res
      |> attribute_fields()
      |> Enum.reject(fn {name, _f} -> String.to_atom(name) in fk_names end)
      |> Enum.map(fn {name, field} -> "    " <> attribute_line(name, field, ctx) end)

    "  attributes do\n#{Enum.join(lines, "\n")}\n  end"
  end

  defp attribute_line(name, field, ctx) do
    atom = ":#{name}"

    cond do
      field.primary_key? and primitive_kind(field.type) == :uuid ->
        "uuid_primary_key #{atom}"

      field.primary_key? ->
        "attribute #{atom}, #{render_type(field.type, ctx)}, primary_key?: true, allow_nil?: false, public?: true"

      true ->
        # Only require the value client-side when the backend has no default to
        # supply it; otherwise the client would reject valid creates.
        required? = field.allow_nil? == false and not field.has_default?
        opts = ", public?: true" <> if(required?, do: ", allow_nil?: false", else: "")
        "attribute #{atom}, #{render_type(field.type, ctx)}#{opts}"
    end
  end

  defp gen_relationships(res, ctx) do
    lines =
      res.relationships
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, rel} -> "    " <> relationship_line(name, rel, ctx) end)
      |> Enum.reject(&(&1 == "    "))

    if lines == [] do
      "  relationships do\n  end"
    else
      "  relationships do\n#{Enum.join(lines, "\n")}\n  end"
    end
  end

  defp relationship_line(name, rel, ctx) do
    dest = client_module(rel.destination, ctx)

    case rel.type do
      :belongs_to ->
        "belongs_to :#{name}, #{dest}, public?: true, attribute_writable?: true"

      :has_many ->
        "has_many :#{name}, #{dest}, public?: true"

      :has_one ->
        "has_one :#{name}, #{dest}, public?: true"

      _ ->
        ""
    end
  end

  defp gen_calculations(res, ctx) do
    pk = List.first(res.primary_key) || :id

    calcs =
      res
      |> loadable_fields()
      |> Enum.map(fn {name, field} -> calculation_block(name, field, pk, ctx) end)

    if calcs == [] do
      ""
    else
      "\n\n  calculations do\n#{Enum.join(calcs, "\n\n")}\n  end"
    end
  end

  defp calculation_block(name, field, pk, ctx) do
    args =
      Enum.map_join(field.arguments, "\n", fn arg ->
        "      argument :#{arg.name}, #{render_type(arg.type, ctx)}, allow_nil?: true"
      end)

    inner = "      public? true" <> if(args == "", do: "", else: "\n" <> args)

    """
        calculate :#{name}, #{render_type(field.type, ctx)}, expr(not is_nil(#{pk})) do
    #{inner}
        end
    """
    |> String.trim_trailing()
  end

  defp gen_actions(res) do
    blocks = Enum.map(res.actions, &action_block(&1, res))
    "  actions do\n#{Enum.join(blocks, "\n\n")}\n  end"
  end

  defp action_block(%{type: :read} = action, _res) do
    opts =
      [primary?(action), if(action.get?, do: "    get? true")]
      |> compact_lines()

    "    read :#{action.name} do\n#{opts}\n    end"
  end

  defp action_block(%{type: :create} = action, res) do
    accept = accept_line(action, res)

    "    create :#{action.name} do\n#{compact_lines([primary?(action), accept])}\n    end"
  end

  defp action_block(%{type: :update} = action, res) do
    lines =
      compact_lines([
        primary?(action),
        # Remote data layer can't do server-side atomic updates.
        "    require_atomic? false",
        accept_line(action, res)
      ])

    "    update :#{action.name} do\n#{lines}\n    end"
  end

  defp action_block(%{type: :destroy} = action, _res) do
    lines = compact_lines([primary?(action), "    require_atomic? false"])
    "    destroy :#{action.name} do\n#{lines}\n    end"
  end

  defp action_block(%{type: :action, name: name}, _res) do
    "    # generic action #{inspect(name)} not yet supported by ash_remote codegen"
  end

  defp accept_line(action, res) do
    attr_names = res |> attribute_fields() |> Enum.map(fn {name, _} -> name end) |> MapSet.new()

    accepted =
      action.inputs
      |> Enum.map(& &1.name)
      |> Enum.filter(&MapSet.member?(attr_names, &1))
      |> Enum.map(&String.to_atom/1)

    "    accept #{inspect(accepted)}"
  end

  defp primary?(%{primary?: true}), do: "    primary? true"
  defp primary?(_), do: nil

  defp compact_lines(lines), do: lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")

  # --- domain --------------------------------------------------------------

  defp gen_domain(ctx) do
    resources =
      ctx.manifest.resources
      |> Map.keys()
      |> Enum.map(&client_module(&1, ctx))
      |> Enum.sort()
      |> Enum.map_join("\n", &"    resource #{&1}")

    source =
      """
      defmodule #{ctx.domain} do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
      #{resources}
        end
      end
      """

    {ctx.domain, source}
  end

  # --- field helpers -------------------------------------------------------

  defp attribute_fields(res), do: fields_of_kind(res, :attribute)
  defp loadable_fields(res), do: fields_of_kind(res, [:calculation, :aggregate])

  defp fields_of_kind(res, kinds) do
    kinds = List.wrap(kinds)

    res.fields
    |> Enum.filter(fn {_name, field} -> field.kind in kinds end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  defp manifest_attribute_names(res) do
    res |> attribute_fields() |> Enum.map(fn {name, _} -> String.to_atom(name) end)
  end

  defp manifest_loadable_names(res) do
    res |> loadable_fields() |> Enum.map(fn {name, _} -> String.to_atom(name) end)
  end

  defp belongs_to_fks(res) do
    res.relationships
    |> Enum.filter(fn {_name, rel} -> rel.type == :belongs_to end)
    |> Enum.map(fn {name, _rel} -> String.to_atom("#{name}_id") end)
  end

  # --- type rendering ------------------------------------------------------

  defp render_type(nil, _ctx), do: ":term"

  defp render_type(%{kind: :type_ref, module: module}, ctx) do
    cond do
      Map.has_key?(ctx.types, module) -> client_module(module, ctx)
      builtin_type?(module) -> inspect(builtin_atom(module))
      true -> ":map"
    end
  end

  defp render_type(%{kind: :array, item_type: item}, ctx) do
    "{:array, #{render_type(item, ctx)}}"
  end

  defp render_type(%{kind: kind}, _ctx), do: inspect(ash_type(kind))

  defp primitive_kind(%{kind: kind}), do: kind
  defp primitive_kind(_), do: nil

  @builtin ~w(string integer boolean uuid date utc_datetime utc_datetime_usec naive_datetime
              time time_usec decimal float atom ci_string binary duration)a

  defp ash_type(kind) when kind in @builtin, do: kind
  defp ash_type(:map), do: :map
  defp ash_type(_), do: :term

  defp builtin_type?(module), do: String.starts_with?(module, "Ash.")

  defp builtin_atom(module) do
    atom = module |> String.split(".") |> List.last() |> Macro.underscore() |> String.to_atom()
    if atom in @builtin, do: atom, else: :map
  end

  # --- module naming -------------------------------------------------------

  defp client_module(backend_module, ctx) do
    rest =
      backend_module
      |> String.split(".")
      |> Enum.drop(length(ctx.prefix))

    Enum.join([ctx.namespace | rest], ".")
  end

  defp common_prefix([]), do: []

  defp common_prefix(modules) do
    segments = Enum.map(modules, &String.split(&1, "."))

    segments
    |> Enum.reduce(&common_leading/2)
    |> then(fn common ->
      # Never consume the final segment of the shortest module (keep a leaf).
      min_len = segments |> Enum.map(&length/1) |> Enum.min()
      Enum.take(common, min(length(common), min_len - 1))
    end)
  end

  defp common_leading(a, b) do
    a
    |> Enum.zip(b)
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> Enum.map(&elem(&1, 0))
  end
end
