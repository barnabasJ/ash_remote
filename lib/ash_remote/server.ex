defmodule AshRemote.Server do
  @moduledoc """
  Server-side RPC core for the `ash_remote` protocol.

  Ported from `ash_typescript`'s RPC pipeline and kept in `ash_remote` so a
  backend can serve the exact protocol `ash_remote` clients speak, without a hard
  dependency on `ash_typescript`. This is the "shared protocol core" that would
  later be extracted into a package used by both.

  Mount it with `AshRemote.Server.Router` (a Plug). These functions are transport
  agnostic — give them the OTP app whose domains are exposed and the decoded
  request params.

      %{"resource" => module_string, "action" => action_name, "fields" => [...],
        "input" => %{...}, "filter" => %{...}, "sort" => "...", "page" => %{...},
        "primary_key" => %{...}, "tenant" => ...}
      => %{"success" => true, "data" => ...}
       | %{"success" => false, "errors" => [%{"type","message","path"}]}

  Actions are addressed by `{resource, action}` (both present in the manifest),
  since the manifest does not serialize an opaque RPC name.
  """

  require Logger

  alias AshRemote.Server.Fields

  @doc "The exposed `{resource, action}` entrypoints across an OTP app's `AshRemote.Rpc` domains."
  @spec entrypoints(atom()) :: [{module(), atom()}]
  def entrypoints(otp_app) do
    otp_app
    |> Ash.Info.domains()
    |> Enum.filter(&AshRemote.Rpc.Info.rpc?/1)
    |> Enum.flat_map(&AshRemote.Rpc.Info.entrypoints/1)
  end

  @doc "Resources that have at least one exposed action."
  def resources(otp_app) do
    otp_app |> entrypoints() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end

  @doc "The realtime-published `{resource, action}` pairs across an OTP app's `AshRemote.Rpc` domains."
  def publications(otp_app) do
    otp_app
    |> Ash.Info.domains()
    |> Enum.filter(&AshRemote.Rpc.Info.rpc?/1)
    |> Enum.flat_map(&AshRemote.Rpc.Info.publications/1)
  end

  @doc "Generate the exposed surface as a JSON `Ash.Info.Manifest` (exactly the `rpc do` block)."
  @spec manifest_json(atom()) :: String.t()
  def manifest_json(otp_app) do
    {:ok, spec} =
      Ash.Info.Manifest.generate(otp_app: otp_app, action_entrypoints: entrypoints(otp_app))

    spec |> manifest_map() |> put_realtime(otp_app) |> Jason.encode!(pretty: true)
  end

  # Advertise only what the server can actually deliver: published mutation
  # actions on resources that attach `AshRemote.Server.Notifier`.
  defp put_realtime(map, otp_app) do
    case realtime_subscriptions(otp_app) do
      [] ->
        map

      subscriptions ->
        Map.put(map, "realtime", %{
          "topic_prefix" => AshRemote.Topics.prefix(),
          "socket_path" => Application.get_env(:ash_remote, :socket_path, "/ash_remote/socket"),
          "subscriptions" => subscriptions
        })
    end
  end

  defp realtime_subscriptions(otp_app) do
    otp_app
    |> publications()
    |> Enum.filter(fn {resource, action} -> deliverable?(resource, action) end)
    |> Enum.group_by(fn {resource, _} -> resource end, fn {_resource, action} -> action end)
    |> Enum.map(fn {resource, actions} ->
      %{
        "resource" => inspect(resource),
        "actions" => actions |> Enum.uniq() |> Enum.map(&to_string/1) |> Enum.sort()
      }
    end)
    |> Enum.sort_by(& &1["resource"])
  end

  defp deliverable?(resource, action_name) do
    AshRemote.Server.Notifier in Ash.Resource.Info.notifiers(resource) and
      mutation_action?(resource, action_name)
  end

  defp mutation_action?(resource, action_name) do
    case Ash.Resource.Info.action(resource, action_name) do
      %{type: type} -> type in [:create, :update, :destroy]
      _ -> false
    end
  end

  # Ash's JsonSerializer (through at least 3.29.3) omits the action `name` from
  # serialized entrypoints and the source/destination attributes from
  # relationships, but the live resources carry them — inject both so the
  # client can call the right action and mirror relationships whose attributes
  # don't follow naming conventions. (Candidate upstream fixes.)
  defp manifest_map(spec) do
    map = Ash.Info.Manifest.JsonSerializer.to_map(spec)

    entrypoints =
      map
      |> Map.get("entrypoints", [])
      |> Enum.zip(spec.entrypoints)
      |> Enum.map(fn {entry, %{action: action}} ->
        update_in(entry, ["action"], &Map.put(&1, "name", to_string(action.name)))
      end)

    resources =
      map
      |> Map.get("resources", [])
      |> Enum.zip(spec.resources)
      |> Enum.map(fn {entry, %{module: module}} ->
        entry
        |> Map.update("relationships", %{}, &inject_relationship_attributes(&1, module))
        |> Map.put("validations", serialize_validations(module))
        |> Map.update("fields", %{}, &inject_calculation_expressions(&1, module))
        |> Map.update("fields", %{}, &inject_aggregate_metadata(&1, module))
      end)

    map
    |> Map.put("entrypoints", entrypoints)
    |> Map.put("resources", resources)
  end

  # Mirrorable global validations, published so the client can validate
  # without a round trip. A validation mirrors when its module is a builtin
  # data check, its opts encode as safe literals, and every `where` condition
  # passes the same test — anything else (function validations, custom
  # modules, non-literal opts) is skipped: the server stays authoritative.
  @mirrorable_validations Enum.map(
                            ~w(ActionIs ArgumentDoesNotEqual ArgumentEquals ArgumentIn
                               AttributeDoesNotEqual AttributeEquals AttributeIn
                               AttributesPresent ByteSize Changing Compare Confirm
                               Match OneOf Present StringLength),
                            &Module.concat(Ash.Resource.Validation, &1)
                          )

  defp serialize_validations(module) do
    module
    |> Ash.Resource.Info.validations()
    |> Enum.flat_map(&serialize_validation/1)
  end

  defp serialize_validation(%Ash.Resource.Validation{validation: {module, opts}} = validation)
       when module in @mirrorable_validations do
    with {:ok, opts_code} <- AshRemote.Literal.encode(opts),
         {:ok, where} <- serialize_where(validation.where),
         true <- is_nil(validation.message) or is_binary(validation.message) do
      [
        %{
          "module" => inspect(module),
          "opts" => opts_code,
          "on" => Enum.map(validation.on, &to_string/1),
          "where" => where,
          "message" => validation.message,
          "only_when_valid" => validation.only_when_valid? || false
        }
      ]
    else
      _ -> []
    end
  end

  defp serialize_validation(_validation), do: []

  defp serialize_where(conditions) do
    conditions
    |> Enum.reduce_while([], fn
      {module, opts}, acc when module in @mirrorable_validations ->
        case AshRemote.Literal.encode(opts) do
          {:ok, code} -> {:cont, [%{"module" => inspect(module), "opts" => code} | acc]}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      :error -> :error
      acc -> {:ok, Enum.reverse(acc)}
    end
  end

  # Mirrorable calculation expressions, published so clients can carry the
  # real expression instead of a placeholder. An expression mirrors when
  # every node is in `AshRemote.Expression`'s safe set (public attribute
  # refs, comparison operators, and/or/not, today()/now(), literal values) —
  # anything else (module calculations, fragments, relationship refs) is
  # skipped: those are proxied by name and the server stays authoritative.
  defp inject_calculation_expressions(fields, module) do
    Map.new(fields, fn {name, field_map} ->
      with "calculation" <- field_map["kind"],
           %Ash.Resource.Calculation{
             calculation: {Ash.Resource.Calculation.Expression, opts}
           } <- Ash.Resource.Info.calculation(module, String.to_existing_atom(name)),
           {:ok, code} <- AshRemote.Expression.encode(opts[:expr], module) do
        {name, Map.put(field_map, "expression", code)}
      else
        _ -> {name, field_map}
      end
    end)
  end

  # Ash's manifest flattens an aggregate to {name, type, aggregate_kind},
  # dropping the relationship/field/filter — so the client can't reconstruct a
  # native aggregate. Inject that metadata for aggregates that are REPRODUCIBLE
  # on the client: a single-hop relationship (mirrored on the client) and, if
  # present, a filter that mirrors (scoped to the DESTINATION resource, whose
  # attributes the filter references). Anything else is left untouched and stays
  # a `remote(...)` proxy calc. This is the aggregate analogue of
  # `inject_calculation_expressions`.
  defp inject_aggregate_metadata(fields, module) do
    Map.new(fields, fn {name, field_map} ->
      case aggregate_metadata(module, name) do
        {:ok, meta} -> {name, Map.merge(field_map, meta)}
        :error -> {name, field_map}
      end
    end)
  end

  defp aggregate_metadata(module, name) do
    with %Ash.Resource.Aggregate{relationship_path: [relationship], field: field, filter: filter} <-
           Ash.Resource.Info.aggregate(module, String.to_existing_atom(name)),
         %{destination: destination} <- Ash.Resource.Info.relationship(module, relationship),
         {:ok, filter_meta} <- encode_aggregate_filter(filter, destination) do
      meta =
        %{"relationship" => to_string(relationship)}
        |> put_present("aggregate_field", field && to_string(field))
        |> Map.merge(filter_meta)

      {:ok, meta}
    else
      _ -> :error
    end
  end

  # An aggregate with no filter carries `nil` or `[]` (the DSL default).
  defp encode_aggregate_filter(empty, _destination) when empty in [nil, []], do: {:ok, %{}}

  defp encode_aggregate_filter(filter, destination) do
    case AshRemote.Expression.encode(filter, destination) do
      {:ok, code} -> {:ok, %{"aggregate_filter" => code}}
      :error -> :error
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp inject_relationship_attributes(relationships, module) do
    Map.new(relationships, fn {name, rel_map} ->
      case Ash.Resource.Info.relationship(module, String.to_existing_atom(name)) do
        %{source_attribute: source, destination_attribute: destination} ->
          {name,
           rel_map
           |> Map.put("source_attribute", to_string(source))
           |> Map.put("destination_attribute", to_string(destination))}

        _ ->
          {name, rel_map}
      end
    end)
  end

  @doc """
  Run an action against the exposed resources. Returns the response envelope.

  `opts` may carry `:client_id` — the realtime client-correlation id from the
  `x-ash-remote-client-id` request header — which is stamped into the mutation
  changeset's context so `AshRemote.Server.Notifier` can echo it back as
  `origin.client_id`.

  Tenant (R-1) is resolved wire-first: `params["tenant"]`, falling back to
  `opts[:tenant]` (the conn's). The wire tenant is input to Ash multitenancy,
  not an auth claim — policies must still scope actors to tenants themselves.
  """
  @spec run_action(atom(), map(), keyword()) :: map()
  def run_action(otp_app, params, opts \\ []) do
    opts = with_wire_tenant(opts, params)

    with {:ok, resource} <- resolve_resource(otp_app, params["resource"]),
         {:ok, action} <- resolve_action(otp_app, resource, params["action"]) do
      %{"success" => true, "data" => dispatch(resource, action, params, opts)}
    end
    |> normalize()
  rescue
    error -> %{"success" => false, "errors" => to_errors(error)}
  end

  @doc """
  Validate an action's input without executing. Returns the response envelope.

  `opts` carries `:actor`/`:tenant` (B1-1/B1-4: this arity and the
  `Server.Router` call site changed together — the validate path previously
  had neither, since `Ash.Changeset.for_create/3` etc. ran with no subject
  opts at all). Tenant resolution mirrors `run_action/3` — wire-first,
  falling back to `opts[:tenant]`.
  """
  @spec validate_action(atom(), map(), keyword()) :: map()
  def validate_action(otp_app, params, opts \\ []) do
    opts = with_wire_tenant(opts, params)

    with {:ok, resource} <- resolve_resource(otp_app, params["resource"]),
         {:ok, action} <- resolve_action(otp_app, resource, params["action"]) do
      input = params["input"] || %{}
      subject_opts = subject_opts(opts)

      subject =
        case action.type do
          :read ->
            Ash.Query.for_read(resource, action.name, input, subject_opts)

          :create ->
            Ash.Changeset.for_create(resource, action.name, input, subject_opts)

          :update ->
            resource |> struct() |> Ash.Changeset.for_update(action.name, input, subject_opts)

          :destroy ->
            resource |> struct() |> Ash.Changeset.for_destroy(action.name, input, subject_opts)
        end

      errors = if valid?(subject), do: [], else: to_errors(errors_of(subject))
      %{"success" => errors == [], "errors" => errors}
    end
    |> normalize()
  rescue
    error -> %{"success" => false, "errors" => to_errors(error)}
  end

  defp with_wire_tenant(opts, params) do
    case params["tenant"] do
      nil -> opts
      tenant -> Keyword.put(opts, :tenant, tenant)
    end
  end

  # --- dispatch ------------------------------------------------------------

  defp dispatch(resource, %{type: :read} = action, params, opts) do
    fields = params["fields"] || []
    {select, load} = Fields.to_select_and_load(resource, fields)
    input = Map.merge(params["input"] || %{}, params["primary_key"] || %{})

    query =
      resource
      |> Ash.Query.for_read(action.name, input, subject_opts(opts))
      |> maybe(&Ash.Query.filter_input/2, params["filter"])
      |> maybe(&Ash.Query.sort_input/2, params["sort"])
      |> Ash.Query.select(select)
      |> Ash.Query.load(load)
      |> apply_page(action, page_opts(params["page"]))

    if get?(action, params) do
      query |> Ash.read_one!() |> then(&Fields.serialize(&1, resource, fields))
    else
      case Ash.read!(query) do
        %{results: results} = page ->
          %{
            "results" => Fields.serialize(results, resource, fields),
            "count" => Map.get(page, :count),
            "type" => page.__struct__ |> Module.split() |> List.last() |> String.downcase()
          }

        results ->
          Fields.serialize(results, resource, fields)
      end
    end
  end

  defp dispatch(resource, %{type: :create} = action, params, opts) do
    fields = params["fields"] || []
    {_select, load} = Fields.to_select_and_load(resource, fields)

    resource
    |> Ash.Changeset.for_create(action.name, params["input"] || %{}, subject_opts(opts))
    |> put_origin_context(opts)
    |> Ash.create!(load: load)
    |> then(&Fields.serialize(&1, resource, fields))
  end

  defp dispatch(resource, %{type: :update} = action, params, opts) do
    fields = params["fields"] || []
    {_select, load} = Fields.to_select_and_load(resource, fields)

    resource
    |> fetch!(params["primary_key"], opts)
    |> Ash.Changeset.for_update(action.name, params["input"] || %{}, subject_opts(opts))
    |> put_origin_context(opts)
    |> Ash.update!(load: load)
    |> then(&Fields.serialize(&1, resource, fields))
  end

  defp dispatch(resource, %{type: :destroy} = action, params, opts) do
    resource
    |> fetch!(params["primary_key"], opts)
    |> Ash.Changeset.for_destroy(action.name, params["input"] || %{}, subject_opts(opts))
    |> put_origin_context(opts)
    |> Ash.destroy!()

    %{}
  end

  # Ash subject opts (actor/tenant/context) resolved from the request and
  # threaded into every action so authorization and multitenancy apply.
  defp subject_opts(opts) do
    [actor: opts[:actor], tenant: opts[:tenant], context: opts[:context]]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Stamp the realtime client-correlation id into the changeset context so
  # AshRemote.Server.Notifier can echo it back as origin.client_id.
  defp put_origin_context(changeset, opts) do
    case Keyword.get(opts, :client_id) do
      nil -> changeset
      client_id -> Ash.Changeset.set_context(changeset, %{ash_remote: %{client_id: client_id}})
    end
  end

  # --- helpers -------------------------------------------------------------

  defp get?(action, params),
    do: Map.get(action, :get?, false) or not is_nil(params["primary_key"])

  defp fetch!(resource, primary_key, opts) when is_map(primary_key) do
    key = Map.new(primary_key, fn {k, v} -> {String.to_existing_atom(to_string(k)), v} end)
    Ash.get!(resource, key, subject_opts(opts))
  end

  # Actions without pagination can still honor a limit/offset request (the
  # client's Ash.get/2, for one, reads with `limit: 2`) — apply them as plain
  # query limit/offset, which is the same read minus the page envelope.
  defp apply_page(query, _action, nil), do: query

  defp apply_page(query, %{pagination: pagination}, opts) when pagination in [nil, false] do
    query
    |> maybe(&Ash.Query.limit/2, opts[:limit])
    |> maybe(&Ash.Query.offset/2, opts[:offset])
  end

  defp apply_page(query, _action, opts), do: Ash.Query.page(query, opts)

  defp page_opts(nil), do: nil

  defp page_opts(page) when is_map(page) do
    opts =
      Enum.flat_map(page, fn
        {"limit", v} -> [limit: v]
        {"offset", v} -> [offset: v]
        {"count", v} -> [count: v]
        _ -> []
      end)

    if opts == [], do: nil, else: opts
  end

  defp maybe(subject, _fun, nil), do: subject
  defp maybe(subject, fun, arg), do: fun.(subject, arg)

  defp resolve_resource(_otp_app, nil), do: {:error, :missing_resource}

  defp resolve_resource(otp_app, module_string) when is_binary(module_string) do
    case AshRemote.Server.ResourceResolver.resolve(
           otp_app,
           :rpc,
           resources(otp_app),
           module_string
         ) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_resource, module_string}}
    end
  end

  defp resolve_action(otp_app, resource, name) when is_binary(name) do
    action_name = String.to_existing_atom(name)

    cond do
      {resource, action_name} not in entrypoints(otp_app) -> {:error, {:unknown_action, name}}
      action = Ash.Resource.Info.action(resource, action_name) -> {:ok, action}
      true -> {:error, {:unknown_action, name}}
    end
  rescue
    ArgumentError -> {:error, {:unknown_action, name}}
  end

  defp resolve_action(_otp_app, _resource, _), do: {:error, :missing_action}

  defp valid?(%Ash.Changeset{valid?: valid?}), do: valid?
  defp valid?(%Ash.Query{valid?: valid?}), do: valid?
  defp errors_of(%{errors: errors}), do: errors

  # --- error handling ------------------------------------------------------

  defp normalize(%{} = envelope), do: envelope
  defp normalize({:error, reason}), do: %{"success" => false, "errors" => to_errors(reason)}

  defp to_errors(errors) when is_list(errors), do: Enum.flat_map(errors, &to_errors/1)

  defp to_errors({:unknown_resource, r}),
    do: [%{"type" => "unknown_resource", "message" => "Unknown resource: #{r}"}]

  defp to_errors({:unknown_action, a}),
    do: [%{"type" => "unknown_action", "message" => "Unknown action: #{a}"}]

  defp to_errors(:missing_resource),
    do: [%{"type" => "invalid", "message" => "Missing resource"}]

  defp to_errors(:missing_action),
    do: [%{"type" => "invalid", "message" => "Missing action"}]

  defp to_errors(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [error])
    |> Enum.map(&format_error/1)
  end

  defp format_error(error) do
    %{
      "type" => error_type(error),
      "message" => safe_message(error),
      "path" => error |> path() |> Enum.map(&to_string/1)
    }
  end

  defp error_type(%mod{}) do
    segments = Module.split(mod)

    cond do
      "Forbidden" in segments -> "forbidden"
      List.last(segments) == "NotFound" -> "not_found"
      List.last(segments) == "Required" -> "required"
      List.last(segments) == "InvalidAttribute" -> "invalid"
      true -> segments |> List.last() |> Macro.underscore()
    end
  end

  defp error_type(_), do: "unknown"

  defp path(%{path: path}) when is_list(path), do: path
  defp path(%{field: field}) when not is_nil(field), do: [field]
  defp path(_), do: []

  # R-5: mirrors the fallback branch every Ash error-rendering library
  # (ash_json_api's `AshJsonApi.Error.to_json_api_errors/4`, ash_graphql's
  # equivalent) uses — key off Splode's `class` field, not the module or a
  # hand-maintained allowlist. `:invalid`/`:forbidden` messages are Ash's OWN
  # construction, meant to be shown to a caller (this covers
  # `Ash.Error.Invalid`, `Ash.Error.Forbidden`, and every `:invalid`-class
  # NotFound variant — `Ash.Error.Query.NotFound` included — for free, since
  # they all declare `class: :invalid` via `use Splode.Error`). Every other
  # class — critically `:unknown` and `:framework`, which is what a
  # non-Ash exception like a raised `FunctionClauseError` becomes after
  # `Ash.Error.to_error_class/1` wraps it in `Ash.Error.Unknown.UnknownError`
  # — carries `Exception.message/1` output that echoes the ORIGINAL raw
  # exception right back (`UnknownError.message/1` is `inspect(error)`), so
  # blindly trusting it leaks exactly what this fix closes. Log the real
  # exception server-side (with a correlation id) and return a generic
  # message instead.
  @safe_classes [:invalid, :forbidden]

  defp safe_message(%{class: class} = error) when class in @safe_classes do
    Exception.message(error)
  rescue
    _ -> generic_message(error)
  end

  defp safe_message(error), do: generic_message(error)

  defp generic_message(error) do
    id = Ash.UUID.generate()

    Logger.error(
      "ash_remote: internal error `#{id}` during RPC dispatch: " <>
        Exception.format_banner(:error, error)
    )

    "internal error (id: #{id})"
  end
end
