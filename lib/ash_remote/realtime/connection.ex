if Code.ensure_loaded?(Slipstream) do
  defmodule AshRemote.Realtime.Connection do
    @moduledoc """
    One Slipstream websocket connection to a base_url, owning all realtime topics
    for the resources grouped under it. Auto-joins every topic on connect,
    rejoins on topic close, and hands each pushed `"notification"` to
    `AshRemote.Realtime.Inbound` inline (preserving per-topic order).

    Reconnect/rejoin/backoff come from Slipstream. Lifecycle transitions are
    published to the connection's registry for `AshRemote.Realtime.listen_lifecycle/1`.
    """
    use Slipstream

    require Logger

    alias AshRemote.Realtime.{ClientId, Event, Inbound}

    def start_link(opts) do
      Slipstream.start_link(__MODULE__, opts)
    end

    @impl Slipstream
    def init(opts) do
      # Register this connection's echo-correlation id under the HTTP base_url so
      # AshRemote.Transport.Req stamps it on writes and we can drop our own echoes.
      client_id = ClientId.register(opts.http_base_url)
      inbound = Map.put(opts.inbound, :client_id, client_id)

      # connect_params (e.g. an auth token) are evaluated ONCE here, in init/1
      # — NOT per connect/reconnect (R-9 correction: the previous comment was
      # misleading). The evaluated map goes on BOTH the socket connect query
      # string — where the server's `connect/3` reads it to authenticate the
      # connection (the ash_authentication hook) — and every channel join
      # payload for the lifetime of THIS socket process; a fresh token only
      # arrives via a new process (e.g. a supervisor restart), whose state
      # (including `:denied`, below) starts empty anyway.
      params = eval(opts.connect_params)

      socket =
        new_socket()
        |> assign(:opts, opts)
        |> assign(:inbound, inbound)
        |> assign(:join_params, params)
        |> assign(:joined, MapSet.new())
        |> assign(:denied, MapSet.new())
        |> assign(:ready?, false)

      case connect(socket,
             uri: with_query(opts.uri, params),
             reconnect_after_msec: opts.reconnect_after_msec,
             rejoin_after_msec: opts.rejoin_after_msec
           ) do
        {:ok, socket} -> {:ok, socket}
        {:error, reason} -> {:stop, reason}
      end
    end

    @impl Slipstream
    def handle_connect(socket) do
      # R-9: a durably-denied topic (server refused the join with a terminal
      # reason) must never be retried — attempting it again every reconnect
      # would drive a `:join_denied` → LifecycleGuard reconcile storm forever
      # for a decision that will not change within this socket process (see
      # the `:denied` state note in init/1).
      topics = socket.assigns.opts.topics -- MapSet.to_list(socket.assigns.denied)

      socket =
        Enum.reduce(topics, socket, fn topic, socket ->
          join(socket, topic, socket.assigns.join_params)
        end)

      {:ok, socket}
    end

    @impl Slipstream
    def handle_join(topic, _response, socket) do
      rejoined? = MapSet.member?(socket.assigns.joined, topic)
      joined = MapSet.put(socket.assigns.joined, topic)
      socket = assign(socket, :joined, joined)

      cond do
        # A join AFTER the first (i.e. after a gap/reconnect) is the "refetch
        # now" signal — deliberately NOT a fake notification.
        rejoined? ->
          emit(socket, :resubscribed, topic)
          {:ok, socket}

        # First time every topic is joined: the connection is fully ready.
        not socket.assigns.ready? and MapSet.size(joined) == length(socket.assigns.opts.topics) ->
          emit(socket, :connected, nil)
          {:ok, assign(socket, :ready?, true)}

        true ->
          {:ok, socket}
      end
    end

    @impl Slipstream
    def handle_message(_topic, "notification", payload, socket) do
      Inbound.replicate(payload, socket.assigns.inbound)
      {:ok, socket}
    end

    def handle_message(_topic, _event, _message, socket), do: {:ok, socket}

    @impl Slipstream
    def handle_topic_close(topic, {:failed_to_join, response}, socket) do
      # Server refused the join (authorization / tenant) — a terminal
      # decision for this socket process (see the `:denied` state note in
      # init/1). Do not retry in a tight loop — track it so `handle_connect/1`
      # excludes it from every future rejoin attempt, and surface the event
      # exactly ONCE (R-9) rather than once per reconnect.
      already_denied? = MapSet.member?(socket.assigns.denied, topic)
      socket = assign(socket, :denied, MapSet.put(socket.assigns.denied, topic))

      unless already_denied? do
        Logger.warning("ash_remote: join denied for #{topic}: #{inspect(response)}")
        emit(socket, :join_denied, topic)
      end

      {:ok, socket}
    end

    def handle_topic_close(topic, _reason, socket) do
      case rejoin(socket, topic) do
        {:ok, socket} -> {:ok, socket}
        {:error, _reason} -> {:ok, socket}
      end
    end

    @impl Slipstream
    def handle_disconnect(_reason, socket) do
      emit(socket, :disconnected, nil)

      case reconnect(socket) do
        {:ok, socket} -> {:ok, socket}
        {:error, reason} -> {:stop, reason, socket}
      end
    end

    # --- lifecycle ----------------------------------------------------------

    defp emit(socket, type, topic) do
      opts = socket.assigns.opts
      meta = if topic, do: Map.get(opts.topic_meta, topic, %{}), else: %{}
      tenant = Map.get(meta, :tenant)

      # A topic can carry several client resources (multiple mirrors of one
      # server source); a gap event must reach every one so each strategy
      # reconciles. Connection-wide events (topic == nil) carry no resource.
      resources = Map.get(meta, :resources, [nil])

      Enum.each(resources, fn resource ->
        event = %Event{
          type: type,
          resource: resource,
          tenant: tenant,
          base_url: opts.http_base_url,
          topic: topic
        }

        Registry.dispatch(opts.registry, :lifecycle, fn entries ->
          for {pid, _} <- entries, do: send(pid, {AshRemote.Realtime, event})
        end)
      end)

      :ok
    end

    # connect_params evaluated per connect — fresh tokens on (re)connect and on
    # supervisor restart.
    defp eval({module, fun, args}), do: apply(module, fun, args)
    defp eval(fun) when is_function(fun, 0), do: fun.()
    defp eval(params) when is_map(params), do: params
    defp eval(nil), do: %{}

    # Merge params into the ws URI query string, so they arrive as `params` in the
    # server socket's `connect/3`.
    defp with_query(uri, params) when map_size(params) == 0, do: uri

    defp with_query(uri, params) do
      parsed = URI.parse(uri)

      query =
        (parsed.query || "")
        |> URI.decode_query()
        |> Map.merge(Map.new(params, fn {k, v} -> {to_string(k), to_string(v)} end))
        |> URI.encode_query()

      URI.to_string(%{parsed | query: query})
    end
  end
else
  defmodule AshRemote.Realtime.Connection do
    @moduledoc false
    def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}

    def start_link(_opts) do
      raise """
      AshRemote realtime requires the :slipstream dependency. Add it to your deps:

          {:slipstream, "~> 1.1"}
      """
    end
  end
end
