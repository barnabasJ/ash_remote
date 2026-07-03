# ash_remote

An Elixir **client** for the `ash_typescript` RPC protocol. A backend publishes a
versioned `Ash.Info.Manifest` JSON artifact describing its RPC-exposed resources,
types, actions, and filter/sort capabilities. `mix ash_remote.gen` consumes that
manifest and generates **standalone** Ash resources — data parts mirrored, actions
as stubs — backed by `AshRemote.DataLayer`, which speaks `/rpc/run` and `/rpc/validate`.
Generated resources depend only on `ash` + `ash_remote` and compile in any Ash app.

## How it works

```
backend (ash + Ash.Info.Manifest)                 client (ash + ash_remote)
  mix ash.manifest.dump ──► manifest.json ──► mix ash_remote.gen ──► generated resources
                                                                       │
   /rpc/run, /rpc/validate  ◄───────────── AshRemote.DataLayer ◄───────┘
```

- The client's `Ash.Query`/changeset is encoded into an RPC body
  (`AshRemote.Encode.{Fields,Filter,Sort,Pagination}`), sent via
  `AshRemote.Transport` (default `Req`), and the response decoded back into resource
  structs. Calculation and aggregate loads fold into the field selection; relationship
  loads currently use Ash's batched follow-up reads (one request per relationship).
- The server is authoritative: generated action stubs carry no changes/validations;
  the backend does the real casting, authorization, and persistence.

## Usage

Generate resources from a manifest:

```sh
mix ash_remote.gen --manifest path/to/manifest.json --namespace MyApp.Remote
```

Configure the base URL (resolved lazily at call time, so one codebase works per env):

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

## Layout

| Path | What |
|------|------|
| `lib/ash_remote/transport/` | `AshRemote.Transport` behaviour + `Req` implementation |
| `lib/ash_remote/protocol.ex` | pure request-body build / response parse |
| `lib/ash_remote/error.ex` | wire errors → `Ash.Error.*` |
| `lib/ash_remote/encode/` | `Ash.Query` → wire (fields, filter, sort, pagination) |
| `lib/ash_remote/data_layer.ex` | `AshRemote.DataLayer` (implements `Ash.DataLayer`) |
| `lib/ash_remote/resource.ex` | `AshRemote.Resource` extension (`remote do ... end`) |
| `lib/ash_remote/manifest/` | manifest loader + normalized structs |
| `lib/ash_remote/gen/` | manifest → resource source |
| `lib/ash_remote/server.ex`, `server/` | server-side RPC core + `AshRemote.Server.Router` plug (ported from ash_typescript; mount it in a backend) |
| `lib/mix/tasks/ash_remote.gen.ex` | the Igniter generator task |
| `test/support/backend/` | a reference backend that mounts `AshRemote.Server.Router` |

## Tests

```sh
mix test
```

The suite includes the full end-to-end path (`test/ash_remote/e2e_test.exs`): dump a
manifest from the reference backend → generate client resources → compile them →
drive CRUD + relationship/calculation/aggregate loads over real HTTP against the
running backend. See `DECISIONS.md` for design decisions.
