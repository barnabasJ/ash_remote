defmodule AshRemote.Gen do
  @moduledoc """
  Turns an `AshRemote.Manifest` into standalone Ash resource source code.

  `generate/2` returns one map per generated module:

    * `kind: :type` — one module per named type (`Ash.Type.Enum` / `Ash.Type.NewType`)
    * `kind: :resource` — one module per resource (attributes, relationships,
      validations, calculations, aggregates, action stubs, and a `remote`
      block), backed by `AshRemote.DataLayer`. Carries `entities:` —
      per-section `{name, code}` snippets so regeneration can add missing
      entities to an existing module instead of rewriting it.
    * `kind: :domain` — a client domain listing the resources (in `resources:`)

  Backend module names are re-namespaced under `:namespace` by stripping the
  longest common prefix. Reproducible aggregates (single-hop relationship the
  client mirrors, plus an optionally mirrored filter) are emitted as NATIVE
  aggregate entities (`count/sum/avg :name, :relationship`), so a caching
  data layer can fold them from related rows. Everything else — mirrorable
  expressions become real `expr(...)` calcs; opaque calculations and
  non-reproducible aggregates become `expr(remote(...))` proxy calcs the
  backend resolves by name (filterable and sortable there).
  """

  alias AshRemote.Gen.Identifier
  alias AshRemote.Manifest

  # The full closed vocabulary of Ash aggregate kinds — mirrors
  # `Mix.Tasks.AshRemote.Gen.@aggregate_calls`. `field.aggregate_kind` is
  # rendered as a bare *function call name*, not an atom literal, so — unlike
  # the `:#{name}`-style splices `Identifier.validate_name!/2` guards — an
  # arbitrary-but-atom-shaped value isn't enough; it must be one of the
  # specific calls `aggregates do ... end` actually supports (see
  # `validate_aggregate_kind!/1`).
  @aggregate_kinds ~w(count sum avg min max first list exists custom)a

  @doc """
  Generate module definitions from a manifest.

  Returns a list of `%{module: String.t(), kind: :type | :resource | :domain,
  source: String.t()}` maps; `:resource` entries also carry `entities:`
  (`%{attributes | relationships | validations | calculations | aggregates |
  actions => [{name, code}]}`) and the `:domain` entry carries `resources:`
  (client module strings).
  """
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
          values =
            Enum.map_join(type.values, ", ", fn value ->
              ":#{Identifier.validate_name!(value, "enum value")}"
            end)

          "  use Ash.Type.Enum, values: [#{values}]"

        subtype ->
          "  use Ash.Type.NewType, subtype_of: #{inspect(subtype)}"
      end

    %{module: module, kind: :type, source: "defmodule #{module} do\n#{body}\nend\n"}
  end

  # --- resources -----------------------------------------------------------

  defp gen_resource(res, ctx) do
    module = client_module(res.module, ctx)
    entities = resource_entities(res, ctx)

    attributes = section(:attributes, entities.attributes, always?: true)
    relationships = section(:relationships, entities.relationships, always?: true)
    validations = section(:validations, entities.validations, gap?: true)
    calculations = section(:calculations, entities.calculations, gap?: true)
    aggregates = section(:aggregates, entities.aggregates, gap?: true)
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
      #{relationships}#{validations}#{calculations}#{aggregates}
      #{actions}
      end
      """

    %{module: module, kind: :resource, source: source, entities: entities}
  end

  # Per-section `{name, code}` snippets — the unit of non-destructive
  # regeneration: an existing module gets the entities it's missing, by name.
  defp resource_entities(res, ctx) do
    fk_names = belongs_to_fks(res)

    pk =
      case List.first(res.primary_key) do
        nil -> :id
        name -> Identifier.validate_name!(name, "primary key attribute name")
      end

    attributes =
      res
      |> attribute_fields()
      |> Enum.reject(fn {name, _f} -> String.to_atom(name) in fk_names end)
      |> Enum.map(fn {name, field} ->
        {String.to_atom(name), attribute_line(name, field, ctx)}
      end)

    relationships =
      res.relationships
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, rel} ->
        {String.to_atom(name), relationship_line(name, rel, res, ctx)}
      end)
      |> Enum.reject(fn {_name, line} -> line == "" end)

    # Reproducible aggregates (relationship + optional mirrorable filter carried
    # by the manifest) become NATIVE client aggregates, so a caching data layer
    # can fold them from the related rows. Everything else — opaque calcs and
    # non-reproducible aggregates — stays a `remote(...)` proxy calc.
    {native_aggregates, calc_like} =
      res
      |> loadable_fields()
      |> Enum.split_with(fn {_name, field} ->
        reproducible_aggregate?(field, res.relationships)
      end)

    calculations =
      Enum.map(calc_like, fn {name, field} ->
        {String.to_atom(name), calculation_block(name, field, pk, ctx)}
      end)

    aggregates =
      Enum.map(native_aggregates, fn {name, field} ->
        {String.to_atom(name), aggregate_block(name, field)}
      end)

    actions =
      res.actions
      |> Enum.reject(&(&1.type == :action))
      |> Enum.map(fn action -> {String.to_atom(action.name), action_block(action, res)} end)

    %{
      attributes: attributes,
      relationships: relationships,
      validations: validation_entities(res),
      calculations: calculations,
      aggregates: aggregates,
      actions: actions
    }
  end

  # The server only publishes validations it deems mirrorable, but a manifest
  # is input — re-verify here so a crafted one can't inject code into the
  # generated resource: builtin validation modules only, safe literal opts.
  @validation_module ~r/^Ash\.Resource\.Validation\.[A-Za-z0-9.]+$/

  defp validation_entities(res) do
    res.validations
    |> Enum.filter(&mirrorable_validation?/1)
    |> Enum.map(fn validation ->
      line = validation_line(validation)
      {line, line}
    end)
  end

  defp mirrorable_validation?(validation) do
    safe_ref? = fn %{module: module, opts: opts} ->
      is_binary(module) and Regex.match?(@validation_module, module) and
        is_binary(opts) and AshRemote.Literal.safe?(opts)
    end

    safe_ref?.(validation) and Enum.all?(validation.where, safe_ref?)
  end

  defp validation_line(validation) do
    where =
      case validation.where do
        [] ->
          nil

        conditions ->
          refs = Enum.map_join(conditions, ", ", &validation_ref(&1.module, &1.opts))
          "where: [#{refs}]"
      end

    opts =
      [
        # [:create, :update] is the DSL default — omit it so the generated
        # line reads like the hand-written one.
        validation.on != [:create, :update] && "on: #{inspect(validation.on)}",
        where,
        validation.message && "message: #{inspect(validation.message)}",
        validation.only_when_valid? && "only_when_valid?: true"
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(", ")

    case opts do
      "" -> "validate #{validation_ref(validation.module, validation.opts)}"
      opts -> "validate #{validation_ref(validation.module, validation.opts)}, #{opts}"
    end
  end

  # Render a validation reference the way the backend author would have
  # written it — `string_length(:title, min: 3)` — whenever calling that
  # builtin reproduces the manifest's opts exactly; otherwise fall back to
  # the always-correct `{Module, opts}` tuple form.
  defp validation_ref(module_string, opts_code) do
    with {:ok, opts} <- AshRemote.Literal.eval(opts_code),
         {:ok, call} <- AshRemote.Gen.Validations.sugar(module_string, opts) do
      call
    else
      _ -> "{#{module_string}, #{opts_code}}"
    end
  end

  defp section(name, entities, opts) do
    lines = Enum.map(entities, fn {_name, code} -> indented(code) end)

    cond do
      lines != [] -> "  #{name} do\n#{Enum.join(lines, joiner(name))}\n  end"
      opts[:always?] -> "  #{name} do\n  end"
      true -> ""
    end
    |> then(fn body ->
      if opts[:gap?] && body != "", do: "\n\n" <> body, else: body
    end)
  end

  # Single-line entities get standard section indentation; multi-line blocks
  # (calculations) already carry their own.
  defp indented(code) do
    if String.contains?(code, "\n"), do: code, else: "    " <> code
  end

  defp joiner(:calculations), do: "\n\n"
  defp joiner(_), do: "\n"

  defp gen_remote(res, ctx) do
    base =
      if ctx.base_url, do: "    base_url #{inspect(ctx.base_url)}\n", else: ""

    realtime =
      if AshRemote.Manifest.realtime?(ctx.manifest, res.module),
        do: "    realtime? true\n",
        else: ""

    """
      remote do
        source #{inspect(res.module)}
        schema_version #{inspect(ctx.manifest.schema_version)}
    #{base}#{realtime}  end
    """
    |> String.trim_trailing()
  end

  defp attribute_line(name, field, ctx) do
    atom = ":#{Identifier.validate_name!(name, "attribute name")}"

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

  defp relationship_line(name, rel, res, ctx) do
    name = Identifier.validate_name!(name, "relationship name")
    dest = client_module(rel.destination, ctx)
    attrs = relationship_attribute_opts(rel)

    case rel.type do
      :belongs_to ->
        # L6 item 4: the FK attribute is deliberately excluded from the
        # `attributes do` block (see `belongs_to_fks/1`) — Ash's own
        # `belongs_to` auto-creates it, but only when the type/nullability
        # the *backend*'s FK column actually has are threaded through here;
        # otherwise Ash falls back to `attribute_type: :uuid, allow_nil?:
        # true` regardless of what the manifest says, silently wrong for a
        # non-uuid or non-nullable FK.
        fk_opts = belongs_to_fk_opts(rel, name, res, ctx)
        "belongs_to :#{name}, #{dest}, public?: true, attribute_writable?: true#{attrs}#{fk_opts}"

      :has_many ->
        "has_many :#{name}, #{dest}, public?: true#{attrs}"

      :has_one ->
        "has_one :#{name}, #{dest}, public?: true#{attrs}"

      _ ->
        ""
    end
  end

  # Mirror the backend's exact source/destination attributes (when the manifest
  # carries them) instead of relying on Ash's name-based inference, which
  # breaks for relationships like `belongs_to :list` (FK `list_id`, not
  # `todo_list_id`) or self-referential `has_many :subtasks`.
  defp relationship_attribute_opts(rel) do
    [source_attribute: rel.source_attribute, destination_attribute: rel.destination_attribute]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map_join(fn {key, value} ->
      ", #{key}: :#{Identifier.validate_name!(value, "relationship attribute name")}"
    end)
  end

  # The manifest publishes the FK column as a normal attribute field (keyed by
  # the same name `belongs_to_fks/1` excludes from `attributes do`) — look it
  # up there for its real type/nullability. `nil` (a manifest that, unlike
  # the reference backend, doesn't publish the FK as its own field) falls
  # back to no explicit opts, i.e. Ash's own `:uuid`/`allow_nil?: true`
  # default — the same fallback behavior as before this fix, just no longer
  # silently wrong when the field data *is* available.
  defp belongs_to_fk_opts(rel, name, res, ctx) do
    fk_name = rel.source_attribute || "#{name}_id"

    case Map.get(res.fields, fk_name) do
      %{kind: :attribute} = field ->
        allow_nil? = field.allow_nil? != false
        ", attribute_type: #{render_type(field.type, ctx)}, allow_nil?: #{allow_nil?}"

      _ ->
        ""
    end
  end

  defp calculation_block(name, field, pk, ctx) do
    name = Identifier.validate_name!(name, "calculation name")

    args =
      Enum.map_join(field.arguments, "\n", fn arg ->
        arg_name = Identifier.validate_name!(arg.name, "calculation argument name")
        # L6 item 3: the manifest's own nullability, not a hardcoded `true` —
        # an argument the backend actually requires (e.g. `allow_nil? false`)
        # must be rejected client-side too, not silently accepted as nil and
        # sent to the backend to fail there instead.
        allow_nil? = arg.allow_nil? != false
        "      argument :#{arg_name}, #{render_type(arg.type, ctx)}, allow_nil?: #{allow_nil?}"
      end)

    inner = "      public? true" <> if(args == "", do: "", else: "\n" <> args)

    # Mirrorable expressions become the real thing (locally evaluable,
    # filterable, sortable). Everything else is emitted as `remote(...)` — a
    # pure expression calc the backend resolves by name (so it is filterable and
    # sortable there), via the `AshRemote.Expressions.Remote` custom expression.
    # The primary key is passed so the expression references a real attribute
    # and Ash routes the calc through the data layer instead of folding it to a
    # literal (see `AshRemote.Expressions.Remote`).
    implementation =
      cond do
        field.expression && AshRemote.Expression.safe?(field.expression) ->
          "expr(#{field.expression})"

        true ->
          arg_map =
            Enum.map_join(field.arguments, ", ", fn arg ->
              arg_name = Identifier.validate_name!(arg.name, "calculation argument name")
              ~s|"#{arg_name}" => arg(:#{arg_name})|
            end)

          ~s|expr(remote("#{name}", %{#{arg_map}}, #{pk}))|
      end

    """
        calculate :#{name}, #{render_type(field.type, ctx)}, #{implementation} do
    #{inner}
        end
    """
    |> String.trim_trailing()
  end

  # A manifest aggregate field is reproducible on the client when the server
  # injected its relationship (a single-hop relationship the client mirrors) —
  # and, if it has a filter, that filter mirrored too. The manifest is input
  # from a source we don't fully trust (B2) — re-verify the filter against
  # `AshRemote.Expression.safe?` here even though a legitimate server only
  # ever publishes filters that already passed this gate, exactly as the
  # calculation path re-verifies `field.expression` below.
  #
  # L6 item 6: a relationship name alone isn't enough — the aggregate is only
  # reproducible if that relationship is one the generator will *actually
  # emit* into `relationships do`. Two ways it might not be, both silent
  # otherwise: `relationship_line/4` doesn't support `:many_to_many` at all
  # (its catch-all clause drops it, emitting nothing), and the manifest may
  # simply not carry a relationship by that name (e.g. private, so never
  # published — `Ash.Info.Manifest` only publishes public relationships).
  # Either way, without this check `aggregate_block/2` would render
  # `count :x, :some_ref do ... end` against a relationship that doesn't
  # exist on the generated resource — uncompilable — instead of falling back
  # to the always-safe `remote(...)` proxy calc.
  defp reproducible_aggregate?(
         %{kind: :aggregate, relationship: relationship} = field,
         relationships
       )
       when not is_nil(relationship) do
    filter = Map.get(field, :aggregate_filter)

    emitted_relationship?(relationships, relationship) and
      (is_nil(filter) or AshRemote.Expression.safe?(filter))
  end

  defp reproducible_aggregate?(_field, _relationships), do: false

  @emitted_relationship_types [:belongs_to, :has_many, :has_one]

  defp emitted_relationship?(relationships, name) do
    case Map.get(relationships, name) do
      %{type: type} -> type in @emitted_relationship_types
      nil -> false
    end
  end

  defp validate_aggregate_kind!(kind) when kind in @aggregate_kinds, do: kind

  defp validate_aggregate_kind!(kind) do
    raise AshRemote.Gen.InvalidManifestError,
      message:
        "manifest aggregate kind #{inspect(kind)} is not one of the supported aggregate " <>
          "calls #{inspect(@aggregate_kinds)}"
  end

  # A native client aggregate: `count :name, :relationship [, :field] do ... end`
  # (with the sum/avg field arg only when present, and a mirrored filter when
  # the server carried one). A caching data layer can fold this from the related
  # rows instead of round-tripping to the server.
  defp aggregate_block(name, field) do
    name = Identifier.validate_name!(name, "aggregate name")
    relationship = Identifier.validate_name!(field.relationship, "aggregate relationship name")
    kind = validate_aggregate_kind!(field.aggregate_kind)

    field_arg =
      if field.aggregate_field,
        do: ", :#{Identifier.validate_name!(field.aggregate_field, "aggregate field name")}",
        else: ""

    filter_line =
      if field.aggregate_filter, do: "\n      filter expr(#{field.aggregate_filter})", else: ""

    """
        #{kind} :#{name}, :#{relationship}#{field_arg} do
          public? true#{filter_line}
        end
    """
    |> String.trim_trailing()
  end

  defp gen_actions(res) do
    blocks = Enum.map(res.actions, &action_block(&1, res))
    "  actions do\n#{Enum.join(blocks, "\n\n")}\n  end"
  end

  # Action names are validated once, here, regardless of which action-type
  # clause below ends up interpolating `action.name` raw.
  defp action_block(action, res) do
    Identifier.validate_name!(action.name, "action name")
    do_action_block(action, res)
  end

  defp do_action_block(%{type: :read} = action, _res) do
    opts =
      [
        primary?(action),
        if(action.get?, do: "    get? true"),
        # Records requested remote calculations in query context so the data
        # layer can prefetch them in the same request.
        "    prepare AshRemote.PrefetchCalculations"
      ]
      |> compact_lines()

    "    read :#{action.name} do\n#{opts}\n    end"
  end

  defp do_action_block(%{type: :create} = action, res) do
    accept = accept_line(action, res)

    "    create :#{action.name} do\n#{compact_lines([primary?(action), accept])}\n    end"
  end

  defp do_action_block(%{type: :update} = action, res) do
    lines =
      compact_lines([
        primary?(action),
        # Remote data layer can't do server-side atomic updates.
        "    require_atomic? false",
        accept_line(action, res)
      ])

    "    update :#{action.name} do\n#{lines}\n    end"
  end

  defp do_action_block(%{type: :destroy} = action, _res) do
    lines = compact_lines([primary?(action), "    require_atomic? false"])
    "    destroy :#{action.name} do\n#{lines}\n    end"
  end

  defp do_action_block(%{type: :action, name: name}, _res) do
    "    # generic action #{inspect(name)} not yet supported by ash_remote codegen"
  end

  defp accept_line(action, res) do
    attr_names = res |> attribute_fields() |> Enum.map(fn {name, _} -> name end) |> MapSet.new()

    accepted =
      action.inputs
      |> Enum.map(& &1.name)
      |> Enum.filter(&MapSet.member?(attr_names, &1))
      |> Enum.map(&String.to_atom/1)

    # Rendered via `inspect/1`, not raw interpolation, so this is already
    # injection-safe regardless of what an accepted name contains — `inspect`
    # on a list of atoms always produces valid, self-escaping Elixir source.
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

    resource_lines = Enum.map_join(resources, "\n", &"    resource #{&1}")

    source =
      """
      defmodule #{ctx.domain} do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
      #{resource_lines}
        end
      end
      """

    %{module: ctx.domain, kind: :domain, source: source, resources: resources}
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

  # L6 item 4 (a preexisting bug this fix also closes): `rel.source_attribute`
  # is a *string* (manifest data) when present, but the `|| String.to_atom(...)`
  # fallback only ran for the nil case — so this returned a list mixing
  # strings and atoms, and `String.to_atom(name) in fk_names` at the call site
  # (an atom-only membership check) silently never matched a present
  # `source_attribute`, i.e. the FK exclusion this function exists for was
  # inert whenever the manifest actually carries `source_attribute` (which,
  # from `AshRemote.Server.inject_relationship_attributes/2`, is always). Both
  # sides now consistently deal in atoms.
  defp belongs_to_fks(res) do
    res.relationships
    |> Enum.filter(fn {_name, rel} -> rel.type == :belongs_to end)
    |> Enum.map(fn {name, rel} -> String.to_atom(rel.source_attribute || "#{name}_id") end)
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

  # The single validation point for every manifest-sourced module name:
  # resource modules, type modules, and relationship destinations all funnel
  # through here. Validating the raw `backend_module` string (every
  # dot-segment a safe Elixir alias component) closes both the `defmodule
  # #{module} do` injection point and — since `Macro.underscore/1` of a
  # validated alias can never contain a `/` or `..` — the file-path
  # derivation in `Mix.Tasks.AshRemote.Gen.output_path/2`.
  defp client_module(backend_module, ctx) do
    Identifier.validate_module!(backend_module, "module name")

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
