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

  There are two layers:

    * **Topic (join) gate** — `authorize_subscription/4`, which **defaults to
      deny**. Return `:ok` (or `{:ok, socket}`) to allow, anything else to deny.
    * **Per-record gate** — the channel computes the actor's read-policy
      filter once at join and evaluates it in-memory against every broadcast
      record before pushing (falling back to a single authorized re-read when
      the filter can't be decided in memory), so a subscription never reveals
      a row the actor could not read (see `AshRemote.Server.Channel`).
      Resources without authorizers skip it.

  Assign the actor for the per-record check to `:ash_remote_actor` on the socket
  — typically in an overridden `connect/3` that authenticates the connection
  token, or in `authorize_subscription/4` (returning `{:ok, socket}`):

      def connect(%{"token" => token}, socket, _info) do
        case MyApp.verify(token) do
          {:ok, user} -> {:ok, Phoenix.Socket.assign(socket, :ash_remote_actor, user)}
          _ -> :error
        end
      end

  For local development you can set
  `config :ash_remote, :dangerously_allow_all_subscriptions, true` to bypass the
  join gate entirely (logged, once). It does not bypass the per-record check.

  ## Revocation is join-time-snapshot, not live (L13)

  `AshRemote.Server.Channel`'s per-record read-policy filter (the "per-record
  gate" above) is computed **once at join** and cached in the channel's own
  socket assigns for that connection's lifetime — never re-evaluated against
  a change in the actor's own authorization state (e.g. a deactivated user,
  a revoked role, a tenant reassignment). A subscriber whose access was
  revoked keeps receiving every broadcast their ORIGINAL join-time filter
  matched until they disconnect, for exactly as long as their connection
  stays open.

  The default `id/1` returns `nil` — Phoenix's own signal that this socket
  has **no identifier for `Phoenix.Endpoint.disconnect/3`
  to target**, so there is no built-in way to force-disconnect a specific
  user's live sockets from application code. This is the current, accepted
  default: closing the gap would require overriding `id/1` (returning a
  string derived from the connected actor, e.g. `"actor:\#{actor.id}"`) so
  `MyAppWeb.Endpoint.disconnect(id, ...)` becomes callable when your
  application detects a revocation, and calling it from wherever your app
  performs the revocation (e.g. a user-deactivation action). `ash_remote`
  does not do this automatically — it would mean tracking authorization
  invalidation as a first-class concept this library doesn't otherwise have
  (see `deferred-follow-ups.md` entry 5 for anything beyond this
  documentation).

  Until you override `id/1`, treat a subscription's authorization as valid
  for the lifetime of its connection: any change that must take effect
  immediately (not just on the next reconnect) needs the `id/1` override
  above plus your own call to `disconnect/3` at revocation time.
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
