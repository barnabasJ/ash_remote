defmodule AshRemote.Realtime do
  @moduledoc """
  Supervises realtime replication for a client app. Add it to your supervision
  tree:

      {AshRemote.Realtime, otp_app: :my_app}

  It discovers every `realtime? true` remote resource across the app's domains,
  groups them by resolved base_url, and starts one websocket `Connection` per
  base_url that auto-joins a topic per resource. Each pushed notification is
  decoded and re-emitted as a local `%Ash.Notifier.Notification{}` (see
  `AshRemote.Realtime.Inbound`), so the client resource's own notifiers
  (`Ash.Notifier.PubSub`, …) fire as if the mutation were local.

  ## Options

    * `:otp_app` — app whose domains are scanned for `realtime?` resources.
    * `:resources` — explicit resource list, bypassing discovery.
    * `:base_url` — websocket base URL override (default: each resource's own
      RPC base_url). Useful when the socket lives on a different host/port than
      the HTTP RPC endpoint.
    * `:socket_path` — endpoint socket mount (default `"/ash_remote/socket"`).
    * `:connect_params` — `map | (-> map) | {m,f,a}`, evaluated on every connect
      so reconnects can carry fresh tokens. Sent as channel join params.
    * `:tenant` — `nil | tenant | {m,f,a}`, the tenant segment for every topic.
    * `:echo` — `:suppress` (default) drops the broadcast copy of the client's
      own writes; `:deliver` delivers them (marked `origin: :remote`).
    * `:name` — supervisor/registry base name (default `AshRemote.Realtime`).

  ## Lifecycle

  Register for `{AshRemote.Realtime, %AshRemote.Realtime.Event{}}` messages with
  `listen_lifecycle/1`. `:resubscribed` after a gap is the documented "refetch
  now" signal (notifications are at-most-once, no replay).
  """
  use Supervisor

  alias AshRemote.Realtime.Connection
  alias AshRemote.Topics

  @default_socket_path "/ash_remote/socket"
  @default_reconnect [200, 500, 1_000, 2_000, 5_000]
  @default_rejoin [200, 500, 1_000, 2_000, 5_000]

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    registry = registry_name(name)

    connection_specs =
      opts
      |> discover_resources()
      |> resolve_configs()
      |> group_by_base_url()
      |> Enum.map(&connection_spec(&1, opts, registry))

    children = [{Registry, keys: :duplicate, name: registry} | connection_specs]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Register the calling process to receive `{AshRemote.Realtime, %Event{}}`
  lifecycle messages from the named supervisor (default `AshRemote.Realtime`).
  """
  def listen_lifecycle(name \\ __MODULE__) do
    Registry.register(registry_name(name), :lifecycle, nil)
  end

  defp registry_name(name), do: Module.concat(name, Lifecycle)

  # --- discovery ------------------------------------------------------------

  defp discover_resources(opts) do
    case Keyword.get(opts, :resources) do
      nil ->
        opts
        |> Keyword.fetch!(:otp_app)
        |> Ash.Info.domains()
        |> Enum.flat_map(&Ash.Domain.Info.resources/1)
        |> Enum.filter(&realtime?/1)
        |> Enum.uniq()

      resources ->
        resources
    end
  end

  defp realtime?(resource) do
    AshRemote.Resource.Info.remote?(resource) and
      AshRemote.Resource.Info.remote_realtime?(resource)
  end

  defp resolve_configs(resources) do
    Enum.map(resources, fn resource ->
      cfg = AshRemote.DataLayer.remote_config(resource)

      %{
        resource: resource,
        source: cfg.source,
        base_url: cfg.base_url,
        action_invert: invert_action_map(cfg[:action_map] || %{})
      }
    end)
  end

  defp invert_action_map(action_map) do
    Map.new(action_map, fn {client_action, backend_action} ->
      {to_string(backend_action), client_action}
    end)
  end

  defp group_by_base_url(configs), do: Enum.group_by(configs, & &1.base_url)

  # --- child specs ----------------------------------------------------------

  defp connection_spec({http_base_url, configs}, opts, registry) do
    tenant = eval_tenant(Keyword.get(opts, :tenant))
    socket_base = Keyword.get(opts, :base_url) || http_base_url
    socket_path = Keyword.get(opts, :socket_path, @default_socket_path)

    topics =
      Map.new(configs, fn cfg -> {cfg.source, Topics.topic(cfg.source, tenant)} end)

    topic_meta =
      Map.new(configs, fn cfg ->
        {topics[cfg.source], %{resource: cfg.resource, tenant: tenant}}
      end)

    sources =
      Map.new(configs, fn cfg ->
        {cfg.source, %{resource: cfg.resource, action_invert: cfg.action_invert}}
      end)

    conn_opts = %{
      uri: websocket_uri(socket_base, socket_path),
      http_base_url: http_base_url,
      topics: Map.values(topics),
      topic_meta: topic_meta,
      connect_params: Keyword.get(opts, :connect_params, %{}),
      registry: registry,
      reconnect_after_msec: Keyword.get(opts, :reconnect_after_msec, @default_reconnect),
      rejoin_after_msec: Keyword.get(opts, :rejoin_after_msec, @default_rejoin),
      inbound: %{sources: sources, echo: Keyword.get(opts, :echo, :suppress)}
    }

    Supervisor.child_spec({Connection, conn_opts}, id: {Connection, http_base_url})
  end

  defp websocket_uri(base_url, socket_path) do
    uri = URI.parse(base_url)
    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    path = String.trim_trailing(socket_path, "/") <> "/websocket"
    URI.to_string(%URI{uri | scheme: scheme, path: path})
  end

  defp eval_tenant({module, fun, args}), do: apply(module, fun, args)
  defp eval_tenant(fun) when is_function(fun, 0), do: fun.()
  defp eval_tenant(tenant), do: tenant
end
