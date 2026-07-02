# TodoServer

The backend for the `ash_remote` example: an Ash app (User/Todo on ETS) that
declares its RPC-exposed surface with the `AshRemote.Rpc` DSL, mounts
`AshRemote.Server.Router`, and publishes a JSON `Ash.Info.Manifest` at
`/manifest.json`.

See `example/README.md` for how to run the monorepo.
