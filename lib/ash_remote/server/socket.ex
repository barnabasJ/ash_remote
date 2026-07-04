defmodule AshRemote.Server.Socket do
  @moduledoc """
  A `Phoenix.Socket` for realtime `ash_remote` subscriptions. The host app mounts
  it in its `Phoenix.Endpoint`:

      defmodule MyAppWeb.RemoteSocket do
        use AshRemote.Server.Socket, otp_app: :my_app

        @impl true
        def authorize_subscription(resource, tenant, _params, _socket) do
          # default is DENY — implement your policy here
          :ok
        end
      end

      # in the endpoint:
      socket "/ash_remote/socket", MyAppWeb.RemoteSocket, websocket: true

  `use AshRemote.Server.Socket` wires `use Phoenix.Socket`, routes
  `ash_remote:*` topics to `AshRemote.Server.Channel`, and stashes the otp_app
  and the socket module in the socket assigns so the channel can enforce
  publication membership and call back into `authorize_subscription/4`.

  ## Authorization

  Channel join is the authorization gate, and it **defaults to deny** — realtime
  broadcasts bypass read policies, so an allow-all default would leak by
  construction. Override `authorize_subscription/4`; return `:ok` (or
  `{:ok, socket}`) to allow, anything else to deny.

  For local development you can set
  `config :ash_remote, :dangerously_allow_all_subscriptions, true` to bypass the
  gate entirely (logged, once).
  """

  @typedoc "Return `:ok`/`{:ok, socket}` to allow the subscription, anything else denies."
  @type authorization :: :ok | {:ok, term} | :error | {:error, term}

  @doc """
  Authorize a subscription to `resource` (optionally scoped to `tenant`). Called
  on channel join with the join `params` and the `Phoenix.Socket`. Defaults to
  deny; override in the host socket module.
  """
  @callback authorize_subscription(
              resource :: module,
              tenant :: String.t() | nil,
              params :: map,
              socket :: term
            ) :: authorization

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)

    quote do
      use Phoenix.Socket

      @behaviour AshRemote.Server.Socket

      channel("ash_remote:*", AshRemote.Server.Channel)

      @ash_remote_otp_app unquote(otp_app)

      @impl Phoenix.Socket
      def connect(params, socket, _connect_info) do
        {:ok,
         socket
         |> Phoenix.Socket.assign(:ash_remote_otp_app, @ash_remote_otp_app)
         |> Phoenix.Socket.assign(:ash_remote_socket_module, __MODULE__)
         |> Phoenix.Socket.assign(:ash_remote_connect_params, params)}
      end

      @impl Phoenix.Socket
      def id(_socket), do: nil

      @impl AshRemote.Server.Socket
      def authorize_subscription(_resource, _tenant, _params, _socket), do: :error

      defoverridable connect: 3, id: 1, authorize_subscription: 4
    end
  end
end
