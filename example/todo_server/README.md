# TodoServer

The backend for the `ash_remote` example: an Ash app (User/TodoList/Todo on ETS)
that declares its RPC-exposed surface with the `AshRemote.Rpc` DSL, mounts
`AshRemote.Server.Router`, publishes a JSON `Ash.Info.Manifest` at
`/manifest.json`, and broadcasts realtime notifications over
`AshRemote.Server.Notifier` — the source of truth both `todo_client` instances
subscribe to.

See `example/README.md` for how to run the monorepo.
