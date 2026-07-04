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

      socket =
        new_socket()
        |> assign(:opts, opts)
        |> assign(:inbound, inbound)
        |> assign(:joined, MapSet.new())
        |> assign(:ready?, false)

      case connect(socket,
             uri: opts.uri,
             reconnect_after_msec: opts.reconnect_after_msec,
             rejoin_after_msec: opts.rejoin_after_msec
           ) do
        {:ok, socket} -> {:ok, socket}
        {:error, reason} -> {:stop, reason}
      end
    end

    @impl Slipstream
    def handle_connect(socket) do
      params = eval(socket.assigns.opts.connect_params)

      socket =
        Enum.reduce(socket.assigns.opts.topics, socket, fn topic, socket ->
          join(socket, topic, params)
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
      # Server refused the join (authorization / tenant). Do not retry in a tight
      # loop — surface it and stop.
      Logger.warning("ash_remote: join denied for #{topic}: #{inspect(response)}")
      emit(socket, :join_denied, topic)
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

      event = %Event{
        type: type,
        resource: Map.get(meta, :resource),
        tenant: Map.get(meta, :tenant),
        base_url: opts.http_base_url,
        topic: topic
      }

      Registry.dispatch(opts.registry, :lifecycle, fn entries ->
        for {pid, _} <- entries, do: send(pid, {AshRemote.Realtime, event})
      end)

      :ok
    end

    # connect_params evaluated per connect — fresh tokens on reconnect.
    defp eval({module, fun, args}), do: apply(module, fun, args)
    defp eval(fun) when is_function(fun, 0), do: fun.()
    defp eval(params) when is_map(params), do: params
    defp eval(nil), do: %{}
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
