# ash_remote example — todo server + LiveView client

A two-project monorepo showing `ash_remote` end to end:

```
example/
  todo_server/   Ash backend. Declares its RPC-exposed surface with the
                 `AshRemote.Rpc` DSL, mounts `AshRemote.Server.Router`, and
                 publishes a JSON Ash.Info.Manifest at /manifest.json.
  todo_client/   A LiveView app. Consumes the manifest, generates standalone Ash
                 resources with `mix ash_remote.gen`, and manages todos from a
                 LiveView using AshPhoenix.Form — every read/write is an RPC call
                 to todo_server via AshRemote.DataLayer.
```

## The flow

```
todo_server ──/manifest.json──►  mix ash_remote.gen  ──►  TodoClient.Remote.{Todo,User,Priority}
     ▲                                                              │
     └──────── /rpc/run ◄──── AshRemote.DataLayer ◄──── TodoClient.Live (AshPhoenix.Form)
```

The LiveView calls `Ash.read!/1`, `AshPhoenix.Form.submit/2`, `Ash.update/3`,
`Ash.destroy!/1` on the **generated** resources exactly as if they were local —
`AshRemote.DataLayer` turns each into an HTTP RPC call to `todo_server`.

## Exposing actions (server)

The backend declares what's exposed, ash_typescript-style:

```elixir
# todo_server/lib/todo_server/domain.ex
use Ash.Domain, extensions: [AshRemote.Rpc]

rpc do
  resource TodoServer.Todo do
    expose :read
    expose :create
    expose :update
    expose :destroy
  end

  resource TodoServer.User do
    expose :read
    expose :create
  end
end
```

and mounts the built-in router (no custom RPC code):

```elixir
# todo_server/lib/todo_server/rpc_router.ex
use AshRemote.Server.Router, otp_app: :todo_server
```

## Look at it (browser)

Two shells:

```sh
# 1) the backend (http://localhost:4010, manifest at /manifest.json)
cd example/todo_server && mix run --no-halt

# 2) the LiveView client — then open http://localhost:4001
cd example/todo_client && mix run --no-halt -e "TodoClient.Web.start()"
```

## Automated end-to-end test (no browser needed)

`todo_client`'s test boots the backend's RPC router in-process and drives the
LiveView (mount → create → toggle → delete), asserting each change round-tripped
to the server:

```sh
cd example/todo_client && HEX_OFFLINE=1 mix test
```

## Regenerate the client resources

Both steps are wired as mix aliases (see each `mix.exs`):

```sh
cd todo_server && mix manifest.publish   # writes ../todo_client/priv/manifest.json
cd ../todo_client && mix remote.gen      # ash_remote.gen → lib/todo_client/remote/*
```

> These projects use local path deps to the sibling `ash` and `ash_remote`
> checkouts (`ash_remote`'s `Ash.Info.Manifest` is unreleased). In this sandbox,
> fetch deps with `HEX_OFFLINE=1 mix deps.get`.
