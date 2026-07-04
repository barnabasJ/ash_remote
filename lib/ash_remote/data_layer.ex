defmodule AshRemote.DataLayer do
  @moduledoc """
  An `Ash.DataLayer` that translates queries and changesets into RPC calls
  against a remote Ash backend.

  Reads/writes fold attribute selection, calculations and aggregates into a
  single `/rpc/run` request. Relationships are loaded by Ash's own batched
  follow-up reads (each of which is itself a remote read), so no lateral-join
  support is advertised.

  Transport/config is resolved via `config/1`: for generated resources it comes
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

  def can?(_resource, :filter), do: true
  def can?(_resource, :boolean_filter), do: true
  def can?(_resource, {:filter_expr, _}), do: true
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
    cfg = remote_config(resource)
    {fields, plan} = query |> Fields.build() |> add_prefetch_calculations(query)

    body =
      Protocol.build_run(%{
        resource: cfg.source,
        action: read_action_name(resource, cfg),
        fields: fields,
        filter: Filter.encode(query.filter, applicable: cfg[:applicable]),
        sort: Sort.encode(query.sort),
        page: Pagination.encode(query)
      })

    with {:ok, response} <- request(cfg, :run, body, request_headers(query.context)),
         {:ok, data} <- Protocol.parse_run(response) do
      {:ok, Decoder.decode_records(data, resource, plan)}
    else
      {:error, errors} when is_list(errors) -> {:error, AshRemote.Error.to_ash_error(errors)}
      {:error, other} -> {:error, other}
    end
  end

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

    body =
      Protocol.build_run(%{
        resource: cfg.source,
        action: map_action(changeset.action.name, cfg),
        primary_key: primary_key(changeset)
      })

    with {:ok, response} <- request(cfg, :run, body, request_headers(changeset.context)),
         {:ok, _data} <- Protocol.parse_run(response) do
      :ok
    else
      {:error, errors} when is_list(errors) -> {:error, AshRemote.Error.to_ash_error(errors)}
      {:error, other} -> {:error, other}
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
          fields: fields
        }
        |> maybe_put(:primary_key, primary_key)
      )

    with {:ok, response} <- request(cfg, :run, body, request_headers(changeset.context)),
         {:ok, data} <- Protocol.parse_run(response) do
      {:ok, Decoder.decode_record(data, resource, plan)}
    else
      {:error, errors} when is_list(errors) -> {:error, AshRemote.Error.to_ash_error(errors)}
      {:error, other} -> {:error, other}
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
  `primary_key in pk_values`, selecting only the primary key plus the given
  calculation specs (`%{name: atom, args: map}`). Returns
  `{:ok, %{calc_name => %{pk_string => value}}}`.

  Used by `AshRemote.RemoteCalculation` when rows were served without this
  data layer running (e.g. from a cache layer) — the whole requested bundle
  is fetched at once so sibling calculations share the round-trip.
  """
  def fetch_remote_calculations(resource, pk_values, specs) do
    cfg = remote_config(resource)
    [pk] = Ash.Resource.Info.primary_key(resource)
    pk_key = to_string(pk)
    filter = Ash.Filter.parse!(resource, [{pk, [in: pk_values]}])

    body =
      Protocol.build_run(%{
        resource: cfg.source,
        action: read_action_name(resource, cfg),
        fields: [pk_key | Enum.map(specs, &calc_spec_field/1)],
        filter: Filter.encode(filter, applicable: cfg[:applicable])
      })

    with {:ok, response} <- request(cfg, :run, body),
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
            {to_string(row[pk_key]), Decoder.cast_calculation(resource, name, row[key])}
          end)}
       end)}
    else
      {:error, errors} when is_list(errors) -> {:error, AshRemote.Error.to_ash_error(errors)}
      {:error, other} -> {:error, other}
    end
  end

  # --- encode helpers ------------------------------------------------------

  defp input(changeset) do
    changeset.attributes
    |> Map.take(accepted_keys(changeset))
    |> Map.merge(changeset.arguments)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
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

  defp request(cfg, path, body, extra_headers \\ []) do
    transport = Map.get(cfg, :transport) || Config.new(base_url: Map.fetch!(cfg, :base_url))
    transport = %{transport | headers: transport.headers ++ extra_headers}
    module = transport.module || Transport.Req
    module.request(transport, path, body)
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
  Resolve the remote wire config for a resource: `%{source, base_url, action_map,
  applicable}`. Prefers the `AshRemote.Resource` extension (generated resources);
  falls back to application env keyed by resource (for resources without the
  extension). Public so the realtime subscriber can resolve source/base_url/
  action_map for `realtime?` resources.
  """
  def remote_config(resource) do
    if AshRemote.Resource.Info.remote?(resource) do
      %{
        source: AshRemote.Resource.Info.remote_source!(resource),
        base_url: base_url(resource),
        action_map: Map.new(AshRemote.Resource.Info.remote_action_map!(resource)),
        applicable: nil
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
