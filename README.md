# ash_remote

An Elixir **client** for the `ash_typescript` RPC protocol. A backend publishes
a versioned `Ash.Info.Manifest` JSON artifact describing its RPC-exposed
resources, types, actions, and filter/sort capabilities. `mix ash_remote.gen`
consumes that manifest and generates **standalone** Ash resources — data parts
mirrored, actions as stubs — backed by `AshRemote.DataLayer`, which speaks
`/rpc/run` and `/rpc/validate`. Generated resources depend only on `ash` +
`ash_remote` and compile in any Ash app.

## How it works

```
backend (ash + Ash.Info.Manifest)                 client (ash + ash_remote)
  mix ash.manifest.dump ──► manifest.json ──► mix ash_remote.gen ──► generated resources
                                                                       │
   /rpc/run, /rpc/validate  ◄───────────── AshRemote.DataLayer ◄───────┘
```

- The client's `Ash.Query`/changeset is encoded into an RPC body
  (`AshRemote.Encode.{Fields,Filter,Sort,Pagination}`), sent via
  `AshRemote.Transport` (default `Req`), and the response decoded back into
  resource structs. Calculation and aggregate loads fold into the field
  selection; relationship loads currently use Ash's batched follow-up reads (one
  request per relationship).
- The server is authoritative: generated action stubs carry no
  changes/validations; the backend does the real casting, authorization, and
  persistence.

## Usage

Generate resources from a manifest:

```sh
mix ash_remote.gen --manifest path/to/manifest.json --namespace MyApp.Remote
```

Configure the base URL (resolved lazily at call time, so one codebase works per
env):

```elixir
# config/runtime.exs
config :ash_remote, base_url: System.fetch_env!("REMOTE_BASE_URL")
```

Then call the generated resources like any Ash resource:

```elixir
MyApp.Remote.Todo
|> Ash.Query.filter(completed == false)
|> Ash.Query.load([:comment_count, :is_overdue, user: [:name]])
|> Ash.read!()
```

Validations declared on backend resources are mirrored onto the generated client
resources when they're expressible as data (builtin validations with literal
options, including `where`-guarded ones) — so forms and changesets fail fast
client-side, while the server re-validates every write. Changes and lifecycle
hooks are never mirrored; they run only on the server.

Debug the wire traffic by logging every RPC request (URL, resource/action,
outcome, duration, request/response bodies):

```elixir
# config/dev.exs
config :ash_remote, debug_requests: true
```

```
[debug] ash_remote: POST http://127.0.0.1:4010/rpc/run TodoServer.Todo.read → ok (4.2ms)
request:  %{"action" => "read", ...}
response: %{"data" => [...], "success" => true}
```

## Realtime

Beyond request/response, `ash_remote` can replicate **server-side Ash
notifications** to connected clients over Phoenix Channels: when a mutation
happens on the server, each subscribed client re-emits an equivalent local
`%Ash.Notifier.Notification{}` on its proxy resource — so client resources can
declare ordinary notifiers (`Ash.Notifier.PubSub` → LiveView, …) and they fire
as if the mutation were local.

**Model: notifications are invalidation hints; reads are truth.** Delivery is
at-most-once with no replay — a reconnect gap loses events, and the
`:resubscribed` lifecycle event is the documented "refetch now" signal.

### Server

```elixir
# resource: attach the notifier
use Ash.Resource, notifiers: [AshRemote.Server.Notifier]

# domain rpc block: name the broadcaster and (optionally) gate publications
rpc do
  pub_sub MyAppWeb.Endpoint      # anything exporting broadcast/3
  resource MyApp.Todo do
    expose :create                # exposing publishes by default
    publish :internal_touch       # opt an unexposed action in
    no_publish :create            # opt out — always wins
  end
end
```

Published set = `(exposed ∪ publish) ∖ no_publish` (mutation actions only).
Mount `AshRemote.Server.Socket` in your endpoint
(`socket "/ash_remote/socket", …`); **channel join defaults to deny** —
implement `authorize_subscription/4`.

### Client

```elixir
# generated resource carries `realtime? true`; add it to your supervision tree:
{AshRemote.Realtime, otp_app: :my_app}
```

`AshRemote.Realtime` discovers `realtime?` resources, opens one Slipstream
socket per base_url, auto-joins a topic each, and re-emits every pushed change
locally (echoes of the client's own writes are suppressed by default). Requires
the optional `:phoenix`/`:phoenix_pubsub` (server) and `:slipstream` (client)
deps.

### Authorization

Two layers, both enforced:

- **RPC** and **socket connect** resolve an actor the same way you already do in
  Ash — an upstream auth plug sets it via `Ash.PlugHelpers` (RPC), or the host
  socket's `connect/3` assigns `:ash_remote_actor` (realtime). Both integrate
  directly with `ash_authentication`.
- **Per-record**: every broadcast is re-checked with
  `Ash.can?({record, :read}, actor)` before it is pushed, so a subscription
  never reveals a row the actor could not have read (resources without policies
  skip the check).

To authenticate, pass the actor — a token in the actor's metadata
(`Ash.read!(RemoteTodo, actor: signed_in_user)`) is auto-forwarded as a Bearer
header, or set explicit `context: %{ash_remote: %{headers: %{…}}}`. See
`example/todo_server` + `example/todo_client` for a full `ash_authentication`
demo (owner-only vs public todos, live).

### Limitations (v1)

- Bulk writes default `notify?: false` → not replicated unless you opt in.
- Generic (`:action`) actions and previous-values topics are not published.
- A notifier's `load/2` on a client resource triggers a remote read.

## Layout

| Path                                                 | What                                                                                                      |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `lib/ash_remote/transport/`                          | `AshRemote.Transport` behaviour + `Req` implementation                                                    |
| `lib/ash_remote/realtime.ex`, `realtime/`            | client realtime supervisor, Slipstream connection, inbound replication                                    |
| `lib/ash_remote/server/{notifier,socket,channel}.ex` | server broadcast notifier + Phoenix socket/channel (join + per-record auth)                               |
| `lib/ash_remote/topics.ex`, `decoder.ex`             | shared topic naming + wire-record decoding                                                                |
| `lib/ash_remote/protocol.ex`                         | pure request-body build / response parse                                                                  |
| `lib/ash_remote/error.ex`                            | wire errors → `Ash.Error.*`                                                                               |
| `lib/ash_remote/encode/`                             | `Ash.Query` → wire (fields, filter, sort, pagination)                                                     |
| `lib/ash_remote/data_layer.ex`                       | `AshRemote.DataLayer` (implements `Ash.DataLayer`)                                                        |
| `lib/ash_remote/resource.ex`                         | `AshRemote.Resource` extension (`remote do ... end`)                                                      |
| `lib/ash_remote/manifest/`                           | manifest loader + normalized structs                                                                      |
| `lib/ash_remote/gen/`                                | manifest → resource source                                                                                |
| `lib/ash_remote/server.ex`, `server/`                | server-side RPC core + `AshRemote.Server.Router` plug (ported from ash_typescript; mount it in a backend) |
| `lib/mix/tasks/ash_remote.gen.ex`                    | the Igniter generator task                                                                                |
| `test/support/backend/`                              | a reference backend that mounts `AshRemote.Server.Router`                                                 |

## Tests

```sh
mix test
```

The suite includes the full end-to-end path (`test/ash_remote/e2e_test.exs`):
dump a manifest from the reference backend → generate client resources → compile
them → drive CRUD + relationship/calculation/aggregate loads over real HTTP
against the running backend. See `DECISIONS.md` for design decisions.
