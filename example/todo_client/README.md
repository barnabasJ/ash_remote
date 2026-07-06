# TodoClient

A LiveView client for the `ash_remote` example. It generates standalone Ash
resources from `todo_server`'s published manifest, wraps them in
`AshMultiDatalayer.DataLayer` (an ETS cache in front of `AshRemote.DataLayer`),
and subscribes to realtime notifications — kept correct across clients by
`AshRemote.MultiDatalayer.ChangeNotifier` and
`AshRemote.MultiDatalayer.LifecycleGuard`.

See `example/README.md` for how to run the monorepo.
