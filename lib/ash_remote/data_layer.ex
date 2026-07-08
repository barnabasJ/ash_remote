defmodule AshRemote.DataLayer do
  @moduledoc """
  An `Ash.DataLayer` that translates queries and changesets into RPC calls
  against a remote Ash backend.

  Reads/writes fold attribute selection, calculations and aggregates into a
  single `/rpc/run` request. Relationships are loaded by Ash's own batched
  follow-up reads (each of which is itself a remote read), so no lateral-join
  support is advertised.

  Transport/config is resolved via `remote_config/1`: for generated resources it comes
  from the `AshRemote.Resource` extension (`remote do … end`); a hand-written
  resource without the extension can instead supply it via application env:

      config :ash_remote, :remote_config, %{
        MyClient.Todo => %{base_url: "...", source: "Backend.Todo", action_map: %{}}
      }
  """
  @behaviour Ash.DataLayer

  alias AshRemote.{Decoder, Protocol, Query, Transport}
  alias AshRemote.Encode.{Fields, Filter, Pagination, Sort}
  alias AshRemote.Transport.Config

  # --- capabilities --------------------------------------------------------

  @impl true
  def can?(_resource, :read), do: true
  def can?(_resource, :create), do: true

  def can?(resource, action_type) when action_type in [:update, :destroy] do
    resource |> Ash.Resource.Info.primary_key() |> Enum.any?()
  end

  # Insert-or-update by primary key. The backend exposes no upsert action, so it
  # is resolved against the live remote row (see `upsert/3`) — enough to make this
  # a valid asynchronous replication target for ash_multi_datalayer's LocalOutbox.
  def can?(resource, :upsert) do
    resource |> Ash.Resource.Info.primary_key() |> Enum.any?()
  end

  def can?(_resource, :filter), do: true
  def can?(_resource, :boolean_filter), do: true
  def can?(_resource, {:filter_expr, expr}), do: Filter.encodable?(expr)
  def can?(_resource, :nested_expressions), do: true
  def can?(_resource, :sort), do: true
  def can?(_resource, {:sort, _}), do: true
  def can?(_resource, :limit), do: true
  def can?(_resource, :offset), do: true
  def can?(_resource, :select), do: true
  def can?(_resource, :expression_calculation), do: true
  def can?(_resource, :expression_calculation_sort), do: true
  def can?(_resource, :calculate), do: true
  def can?(_resource, {:aggregate, _kind}), do: true
  def can?(_resource, {:aggregate_relationship, _}), do: true
  def can?(_resource, {:query_aggregate, _kind}), do: true
  def can?(_resource, :aggregate_filter), do: true
  def can?(_resource, :aggregate_sort), do: true
  # R-1: a client resource must be able to declare `multitenancy do ... end` —
  # the wire tenant is threaded through `run_query/2`/`write/5`/`destroy/2`
  # (see `set_tenant/3`), never dropped.
  def can?(_resource, :multitenancy), do: true
  # No lateral joins: Ash loads relationships via separate (batched) remote reads.
  def can?(_resource, {:join, _}), do: false
  def can?(_resource, :transact), do: false
  def can?(_resource, _), do: false

  # --- query building ------------------------------------------------------

  @impl true
  def resource_to_query(resource, domain), do: %Query{resource: resource, domain: domain}

  @impl true
  def filter(query, filter, _resource), do: {:ok, %{query | filter: filter}}

  @impl true
  def sort(query, sort, _resource), do: {:ok, %{query | sort: sort}}

  @impl true
  def limit(query, limit, _resource), do: {:ok, %{query | limit: limit}}

  @impl true
  def offset(query, offset, _resource), do: {:ok, %{query | offset: offset}}

  @impl true
  def select(query, select, _resource), do: {:ok, %{query | select: select}}

  @impl true
  def add_calculation(query, calculation, _expression, _resource) do
    {:ok, %{query | calculations: [calculation | query.calculations]}}
  end

  @impl true
  def add_aggregate(query, aggregate, _resource) do
    {:ok, %{query | aggregates: [aggregate | query.aggregates]}}
  end

  @impl true
  def set_context(_resource, query, context), do: {:ok, %{query | context: context}}

  @impl true
  def set_tenant(_resource, query, tenant), do: {:ok, %{query | tenant: tenant}}

  # --- read ----------------------------------------------------------------

  @impl true
  def run_query(%Query{resource: resource} = query, _resource) do
    if query.filter == false or match?(%Ash.Filter{expression: false}, query.filter) do
      {:ok, []}
    else
      do_run_query(query, resource)
    end
  end

  defp do_run_query(%Query{resource: resource} = query, _resource) do
    cfg = remote_config(resource)
    {fields, plan} = query |> Fields.build() |> add_prefetch_calculations(query)

    body =
      Protocol.build_run(%{
        resource: cfg.source,
        action: read_action_name(resource, cfg),
        fields: fields,
        filter: Filter.encode(query.filter),
        sort: Sort.encode(query.sort),
        page: Pagination.encode(query),
        tenant: query.tenant
      })

    with {:ok, response} <-
           request(cfg, :run, body, request_headers(query.context), idempotent?: true),
         {:ok, data} <- Protocol.parse_run(response),
         {:ok, records} <- Decoder.decode_records(data, resource, plan, get?: get?(query)) do
      {:ok, records}
    else
      {:error, errors} when is_list(errors) -> {:error, AshRemote.Error.to_ash_error(errors)}
      {:error, other} -> {:error, AshRemote.Error.Transport.normalize(other)}
    end
  end

  # M11: whether this read's action is declared `get?: true` (or `get_by`,
  # which implies it) — the same signal the server uses
  # (`AshRemote.Server.get?/2`'s first clause) to decide between a
  # single-object and a list response shape. Determines how `nil`/a bare
  # object in the response should be interpreted.
  defp get?(%Query{context: %{action: %{get?: get?}}}), do: get? == true
  defp get?(_query), do: false

  # --- writes --------------------------------------------------------------

  @impl true
  def create(resource, changeset) do
    write(resource, changeset, changeset.action.name, input(changeset), nil)
  end

  @impl true
  def update(resource, changeset) do
    write(resource, changeset, changeset.action.name, input(changeset), primary_key(changeset))
  end

  @impl true
  def destroy(resource, changeset) do
    cfg = remote_config(resource)

    # `AshMultiDatalayer.Backfill.destroy_record/4` (the LocalOutbox flush path)
    # hands us an action-less changeset — `data` carries the row, but there is no
    # `action` — mirroring the `upsert/3` case. Resolve the primary destroy action
    # rather than dereferencing `changeset.action.name` on `nil`.
    action = changeset.action || Ash.Resource.Info.primary_action!(resource, :destroy)

    body =
      Protocol.build_run(%{
        resource: cfg.source,
        action: map_action(action.name, cfg),
        primary_key: primary_key(changeset),
        tenant: changeset.to_tenant
      })

    with {:ok, response} <-
           request(cfg, :run, body, request_headers(changeset.context), idempotent?: false),
         {:ok, _data} <- Protocol.parse_run(response) do
      :ok
    else
      {:error, errors} when is_list(errors) -> {:error, AshRemote.Error.to_ash_error(errors)}
      {:error, other} -> {:error, AshRemote.Error.Transport.normalize(other)}
    end
  end

  @impl true
  # Upsert for replication (ash_multi_datalayer LocalOutbox). The remote has
  # no upsert action, so resolve it: read the row by the upsert identity
  # (`keys` — the primary key when no non-PK `upsert_identity` was named, per
  # H2) and dispatch to this layer's own `update` (present) or `create`
  # (absent). Idempotent under flush retries — a re-flushed create finds its
  # row and updates instead of colliding.
  #
  # Backfill hands us an action-less changeset (attributes force-changed,
  # `data` empty), so set the resource's primary write action and, for the
  # update path, address the row by the FOUND row's actual primary key (H2
  # pass-7 High) — not one rebuilt from the incoming changeset's attributes,
  # which may lack (or carry a stale) primary key when resolved by a non-PK
  # identity.
  #
  # R-7: this read-then-write is NOT atomic — two concurrent upserts for the
  # same identity can both observe `{:ok, nil}` and both attempt `create`;
  # the second collides against the server's own uniqueness check. Handle
  # it: on a `:invalid`-class create failure, re-read and retry ONCE as an
  # update — if the row exists now (the other upsert won the race), converge
  # onto it instead of surfacing a collision the caller never asked about.
  # This doesn't close the window (a THIRD concurrent write between the
  # retry's read and its update could still race) — a true fix needs a
  # server-side identity upsert, filed as a follow-up against the protocol.
  def upsert(resource, changeset, keys) do
    keys = if keys in [nil, []], do: Ash.Resource.Info.primary_key(resource), else: keys

    case remote_identity_row(resource, changeset, keys) do
      {:ok, nil} -> create_or_retry_as_update(resource, changeset, keys)
      {:ok, row} -> update(resource, put_write_action(resource, changeset, :update, row))
      {:error, error} -> {:error, error}
    end
  end

  defp create_or_retry_as_update(resource, changeset, keys) do
    case create(resource, put_write_action(resource, changeset, :create)) do
      {:ok, record} ->
        {:ok, record}

      {:error, %{class: :invalid}} = collision ->
        case remote_identity_row(resource, changeset, keys) do
          {:ok, nil} -> collision
          {:ok, row} -> update(resource, put_write_action(resource, changeset, :update, row))
          {:error, _} -> collision
        end

      {:error, _} = error ->
        error
    end
  end

  # H2: `upsert/3`'s changeset arrives action-less from a replicated/backfill
  # write (Backfill.upsert_record builds `Ash.Changeset.new()` — no action,
  # so `accepted_keys/1` already converges every force-changed field). But
  # RESOLVING an upsert here assigns a REAL action (`primary_action!`), and
  # that action may carry its own, narrower `accept` list — silently
  # truncating a replicated write down to whatever an ordinary user action
  # would accept. Mark it as a replicated write so `accepted_keys/1` keeps
  # converging every attribute regardless of the resolved action's accept —
  # the split is "replicated write" vs "user action", not "action-less".
  defp put_write_action(resource, changeset, :create) do
    # Only mark as replicated when WE resolved the default action (the
    # caller's changeset had none — the backfill/action-less shape) — a
    # genuine `Ash.create!(..., upsert?: true)` call already carries its
    # own action + accept list and must keep respecting it.
    replicated? = is_nil(changeset.action)

    changeset = %{
      changeset
      | action: changeset.action || Ash.Resource.Info.primary_action!(resource, :create)
    }

    if replicated?, do: mark_replicated_write(changeset), else: changeset
  end

  # H2: addresses the row by `found_row`'s own primary key — the row the
  # identity lookup (`keys`, possibly non-PK) actually found — never a
  # primary key rebuilt from the incoming changeset's attributes, which may
  # be absent (a replicated write resolved purely by a non-PK identity) or
  # stale.
  defp put_write_action(resource, changeset, :update, found_row) do
    data =
      Enum.reduce(Ash.Resource.Info.primary_key(resource), changeset.data, fn key, acc ->
        Map.put(acc, key, Map.get(found_row, key))
      end)

    %{
      changeset
      | action: Ash.Resource.Info.primary_action!(resource, :update),
        data: data
    }
    |> mark_replicated_write()
  end

  defp mark_replicated_write(changeset) do
    Ash.Changeset.set_context(changeset, %{private: %{ash_remote_replicated_write?: true}})
  end

  # H2: the lookup filter comes from `keys` (the upsert identity — the
  # primary key, or a named non-PK `upsert_identity`), not hardcoded to the
  # primary key, for BOTH the initial lookup and the create-collision retry.
  defp remote_identity_row(resource, changeset, keys) do
    filter_map =
      Map.new(keys, fn key -> {key, Ash.Changeset.get_attribute(changeset, key)} end)

    query = %Query{
      resource: resource,
      domain: changeset.domain || Ash.Resource.Info.domain(resource),
      filter: Ash.Filter.parse!(resource, filter_map),
      context: changeset.context || %{},
      tenant: changeset.to_tenant
    }

    case run_query(query, resource) do
      {:ok, [row | _]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  defp write(resource, changeset, action_name, input, primary_key) do
    cfg = remote_config(resource)
    {fields, plan} = Decoder.write_fields(resource)

    body =
      Protocol.build_run(
        %{
          resource: cfg.source,
          action: map_action(action_name, cfg),
          input: input,
          fields: fields,
          tenant: changeset.to_tenant
        }
        |> maybe_put(:primary_key, primary_key)
      )

    with {:ok, response} <-
           request(cfg, :run, body, request_headers(changeset.context), idempotent?: false),
         {:ok, data} <- Protocol.parse_run(response) do
      {:ok, Decoder.decode_record(data, resource, plan)}
    else
      {:error, errors} when is_list(errors) -> {:error, AshRemote.Error.to_ash_error(errors)}
      {:error, other} -> {:error, AshRemote.Error.Transport.normalize(other)}
    end
  end

  # Remote (module-based) calculations requested by the read, recorded in
  # query context by AshRemote.PrefetchCalculations: fold them into the same
  # request and stash the values in record metadata, so RemoteCalculation
  # makes no follow-up request when the data layer served the rows.
  defp add_prefetch_calculations({fields, plan}, %Query{context: context}) do
    specs = get_in(context || %{}, [:ash_remote, :prefetch_calcs]) || []

    extra_fields = Enum.map(specs, &calc_spec_field/1)
    extra_plan = Enum.map(specs, &{to_string(&1.name), {:remote_calc_meta, &1.name}})

    {fields ++ extra_fields, plan ++ extra_plan}
  end

  defp calc_spec_field(%{name: name, args: args}) when args == %{}, do: to_string(name)

  defp calc_spec_field(%{name: name, args: args}) do
    %{to_string(name) => %{"args" => Map.new(args, fn {k, v} -> {to_string(k), v} end)}}
  end

  @doc """
  Fetches remote-calculation values for a set of records in ONE request:
  every record's full primary key OR'd together, selecting only the primary
  key attributes plus the given calculation specs (`%{name: atom, args:
  map}`). Returns `{:ok, %{calc_name => %{pk_map => value}}}`, keyed by
  `pk_wire_key/2`.

  Used by `AshRemote.RemoteCalculation` when rows were served without this
  data layer running (e.g. from a cache layer) — the whole requested bundle
  is fetched at once so sibling calculations share the round-trip.

  `pk_values` is a list of full-primary-key maps (`Map.take(record,
  primary_key)`-shaped) — L7-3: a single-attribute `[pk] =
  Ash.Resource.Info.primary_key(resource)` destructure used to crash with
  `MatchError` for any composite (multi-attribute) primary key. Keying by the
  FULL primary key works identically for single- and multi-attribute PKs
  (the same fix ash_multi_datalayer's L1 applied to its own aggregate-fold
  paths — `Map.take/2` instead of a single-key match).

  `opts` accepts `:actor` and `:context` (the calculation's `source_context`
  — carries `ash_remote.headers` for explicit request headers) so the bundle
  request authenticates the same way an ordinary read does (H1) — a bundled
  fetch omitting these previously ran fully unauthenticated, denying the
  legitimate actor or (worse) computing values with no authorization
  context at all.
  """
  @spec fetch_remote_calculations(module(), [map()], [map()], term(), keyword()) ::
          {:ok, %{atom() => %{map() => term()}}} | {:error, term()}
  def fetch_remote_calculations(resource, pk_values, specs, tenant \\ nil, opts \\ []) do
    cfg = remote_config(resource)
    primary_key = Ash.Resource.Info.primary_key(resource)
    pk_fields = Enum.map(primary_key, &to_string/1)
    filter = Ash.Filter.parse!(resource, or: pk_values)

    body =
      Protocol.build_run(%{
        resource: cfg.source,
        action: read_action_name(resource, cfg),
        fields: pk_fields ++ Enum.map(specs, &calc_spec_field/1),
        filter: Filter.encode(filter),
        tenant: tenant
      })

    headers = request_headers(bundle_request_context(opts))

    with {:ok, response} <- request(cfg, :run, body, headers, idempotent?: true),
         {:ok, data} <- Protocol.parse_run(response) do
      rows =
        case data do
          %{"results" => results} -> results
          results when is_list(results) -> results
        end

      {:ok,
       Map.new(specs, fn %{name: name} ->
         key = to_string(name)

         {name,
          Map.new(rows, fn row ->
            {pk_wire_key(row, primary_key), Decoder.cast_calculation(resource, name, row[key])}
          end)}
       end)}
    else
      {:error, errors} when is_list(errors) -> {:error, AshRemote.Error.to_ash_error(errors)}
      {:error, other} -> {:error, AshRemote.Error.Transport.normalize(other)}
    end
  end

  @doc """
  A stable, string-keyed lookup key for a record's (or a wire row's) full
  primary key, given `primary_key` (`Ash.Resource.Info.primary_key/1`'s
  result) — same shape whichever side builds it: `Map.get(source, field)`
  for a native record (atom keys) falls back to `Map.get(source,
  to_string(field))` for a wire row (JSON-decoded, string keys), and every
  value is stringified so both sides land on the identical map. Public so
  `AshRemote.RemoteCalculation` can build the matching lookup key for a
  fetched bundle from `fetch_remote_calculations/5`.
  """
  @spec pk_wire_key(map(), [atom()]) :: map()
  def pk_wire_key(source, primary_key) do
    Map.new(primary_key, fn field ->
      value = Map.get(source, field, Map.get(source, to_string(field)))
      {to_string(field), to_string(value)}
    end)
  end

  # --- encode helpers ------------------------------------------------------

  defp input(changeset) do
    changeset.attributes
    |> Map.take(accepted_keys(changeset))
    |> Map.merge(changeset.arguments)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  # H2: a replicated write (LocalOutbox backfill, or upsert/3's internal
  # create/update resolution — see `mark_replicated_write/1`) converges
  # every provided field regardless of the resolved action's `accept` — the
  # split is "replicated write" vs "user action", not "action-less" (an
  # action-less changeset already falls through to the all-attributes
  # clause below, but a REPLICATED write can still carry a real,
  # accept-narrowed action once `put_write_action/3,4` resolves one).
  defp accepted_keys(%{context: %{private: %{ash_remote_replicated_write?: true}}} = changeset) do
    # Neither the primary key NOR any other `writable?: false` attribute
    # (e.g. auto-managed `inserted_at`/`updated_at` timestamps) is valid
    # wire input — the remote correctly rejects any of them as an input
    # attribute for its resolved action ("No such input `X` ... is
    # currently writable?: false"). `changeset.attributes` carries every
    # attribute the local snapshot had a value for, including these (a
    # fresh create's lazy uuid default lands there even though the PK
    # isn't user-writable; a hydrated snapshot's timestamps land there the
    # same way) — so all non-writable attributes must be excluded here
    # explicitly, not just the PK.
    unwritable =
      changeset.resource
      |> Ash.Resource.Info.attributes()
      |> Enum.reject(& &1.writable?)
      |> Enum.map(& &1.name)
      |> MapSet.new()
      |> MapSet.union(MapSet.new(Ash.Resource.Info.primary_key(changeset.resource)))

    changeset.attributes |> Map.keys() |> Enum.reject(&(&1 in unwritable))
  end

  defp accepted_keys(%{action: %{accept: accept}}) when is_list(accept), do: accept

  defp accepted_keys(changeset) do
    changeset.resource |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)
  end

  defp primary_key(changeset) do
    resource = changeset.resource
    record = changeset.data

    resource
    |> Ash.Resource.Info.primary_key()
    |> Map.new(fn key -> {to_string(key), Map.get(record, key)} end)
  end

  defp read_action_name(resource, cfg) do
    case Ash.Resource.Info.primary_action(resource, :read) do
      %{name: name} -> map_action(name, cfg)
      _ -> raise "#{inspect(resource)} has no primary read action"
    end
  end

  defp map_action(name, cfg) do
    cfg |> Map.get(:action_map, %{}) |> Map.get(name, name) |> to_string()
  end

  # --- transport / config --------------------------------------------------

  # `opts[:idempotent?]` (required — every call site states it explicitly,
  # deliberately no default) is L7-2: whatever `retry` the transport config
  # carries (`Config.new(retry: ...)`, or a resource's declared transport) is
  # meant for safely-retriable requests. A create/update/destroy POST is NOT
  # idempotent — retrying one after a transient failure (timeout, connection
  # reset) risks the backend having actually applied the first attempt,
  # double-applying the write on retry (a duplicate create, a second
  # decrement, etc.). Reads (`run_query/2`, `fetch_remote_calculations/5`)
  # and the internal upsert-resolution read (`remote_identity_row/3`, itself
  # a `run_query/2` call) are safe to retry and keep whatever policy the
  # transport config declares; every write call site forces `retry: false`
  # here regardless of that config, so a misconfigured shared transport can
  # never silently make a write retriable.
  defp request(cfg, path, body, extra_headers, opts) do
    idempotent? = Keyword.fetch!(opts, :idempotent?)
    transport = Map.get(cfg, :transport) || Config.new(base_url: Map.fetch!(cfg, :base_url))
    transport = %{transport | headers: merge_headers(transport.headers, extra_headers)}
    transport = if idempotent?, do: transport, else: %{transport | retry: false}
    module = transport.module || Transport.Req
    module.request(transport, path, body)
  end

  # L7-1: the transport's static, configured headers (`Config.new(headers:
  # ...)`, e.g. a fixed service token set once at config time) and this
  # call's per-request headers (`request_headers/1` — the calling actor's
  # forwarded token, or an explicit `context: %{ash_remote: %{headers:
  # ...}}}` header) can both carry an `authorization` entry. Concatenating
  # them naively (`transport.headers ++ extra_headers`, the old code) could
  # hand the backend TWO `authorization` headers for one request — HTTP
  # leaves multiple same-name headers ambiguous (different servers pick the
  # first, the last, or reject the request outright), so this must be
  # resolved on the client, case-insensitively (header names are
  # case-insensitive per RFC 7230).
  #
  # Precedence: the per-request header wins. It is the more specific of the
  # two — either the calling actor's own forwarded token or an explicit
  # header the caller set for this exact call — while the transport-level
  # header is just a static default with no idea who is actually calling. A
  # stale static default silently overriding the real caller's identity is
  # the more dangerous failure mode (the backend authorizes the request as
  # the wrong principal, e.g. a shared service account instead of the
  # signed-in user); the reverse (a static header the caller didn't expect
  # to be overridden) is easy to avoid by simply not setting a per-request
  # header when a fixed one is intended.
  defp merge_headers(base, extra) do
    extra_names = MapSet.new(extra, fn {name, _value} -> String.downcase(name) end)

    kept_base =
      Enum.reject(base, fn {name, _value} ->
        MapSet.member?(extra_names, String.downcase(name))
      end)

    kept_base ++ extra
  end

  # H1: builds `request_headers/1`'s expected shape
  # (`%{private: %{actor: actor}, ash_remote: %{headers: ...}}`) from the
  # `opts` a bundled remote-calculation fetch is called with — `:actor` and
  # `:context` (a calculation's `source_context`, the ORIGINAL read's
  # context, which is where `context: %{ash_remote: %{headers: ...}}}`
  # passed to that read/load call ends up).
  defp bundle_request_context(opts) do
    %{private: %{actor: opts[:actor]}, ash_remote: get_in(opts[:context] || %{}, [:ash_remote])}
  end

  # Per-request headers forwarded to the backend so it can authenticate the call.
  # Two sources, explicit winning on conflict:
  #
  #   * the actor's token metadata — `Ash.read!(RemoteTodo, actor: user)` where
  #     `user` carries the JWT ash_authentication attaches on sign-in
  #     (`Ash.Resource.get_metadata(user, :token)`) — forwarded as a Bearer token
  #     with no boilerplate; and
  #   * explicit headers in the action context, for full control:
  #     `context: %{ash_remote: %{headers: %{"authorization" => ...}}}`.
  #
  # The server's auth plug verifies them and sets the actor, so the RPC action
  # authorizes as the calling user.
  defp request_headers(context) do
    (actor_token_headers(context) ++ explicit_headers(context))
    |> Map.new(fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)
    |> Map.to_list()
  end

  defp explicit_headers(context) do
    case get_in(context || %{}, [:ash_remote, :headers]) do
      headers when is_map(headers) -> Map.to_list(headers)
      _ -> []
    end
  end

  defp actor_token_headers(context) do
    key = Application.get_env(:ash_remote, :actor_token_metadata_key, :token)

    with true <- not is_nil(key),
         actor when is_struct(actor) <- get_in(context || %{}, [:private, :actor]),
         token when is_binary(token) <- actor_token(actor, key) do
      [{"authorization", "Bearer " <> token}]
    else
      _ -> []
    end
  end

  defp actor_token(actor, key) do
    Ash.Resource.get_metadata(actor, key)
  rescue
    _ -> nil
  end

  @doc """
  Resolve the remote wire config for a resource: `%{source, base_url,
  action_map}`. Prefers the `AshRemote.Resource` extension (generated
  resources); falls back to application env keyed by resource (for resources
  without the extension). Public so the realtime subscriber can resolve
  source/base_url/action_map for `realtime?` resources.
  """
  @spec remote_config(module()) :: %{
          source: String.t(),
          base_url: String.t(),
          action_map: map()
        }
  def remote_config(resource) do
    if AshRemote.Resource.Info.remote?(resource) do
      %{
        source: AshRemote.Resource.Info.remote_source!(resource),
        base_url: base_url(resource),
        action_map: Map.new(AshRemote.Resource.Info.remote_action_map!(resource))
      }
    else
      case Application.get_env(:ash_remote, :remote_config) do
        nil -> raise "no :remote_config configured for AshRemote.DataLayer"
        map -> Map.fetch!(map, resource)
      end
    end
  end

  defp base_url(resource) do
    resource_base_url =
      case AshRemote.Resource.Info.remote_base_url(resource) do
        {:ok, url} -> url
        :error -> nil
      end

    resource_base_url || Application.get_env(:ash_remote, :base_url) ||
      raise "no base_url: set `config :ash_remote, :base_url` or the resource's remote base_url"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
