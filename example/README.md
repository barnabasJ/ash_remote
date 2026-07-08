# ash_remote example — cross-client cache invalidation + offline-first, live

> Lineage: this demo previously lived in its own `ash_remote_cache` repo. That
> library's bridge modules were folded into `ash_remote` itself (as
> `AshRemote.MultiDatalayer.*`) and its self-heal/invalidation primitives into
> `ash_multi_datalayer`'s public API — so the example now ships here.

A three-project demo: one backend, two independent LiveView client instances
(different users, different browser tabs), showing `ash_remote`'s realtime
notifications and `ash_multi_datalayer`'s row-aware local authority working
together — via the `AshRemote.MultiDatalayer.*` utilities `ash_remote` ships.

```
example/
  todo_server/   The auth authority AND resource/realtime server, on one
                 Phoenix endpoint. ash_authentication issues JWTs; Todo/TodoList
                 are owned by the signed-in user (owner-only, or public); the
                 domain exposes them over RPC and publishes changes with
                 AshRemote.Server.Notifier.
  todo_client/   A LiveView app with ash_remote's auth/session/realtime wiring.
                 Generated TodoClient.Remote.{Todo,TodoList} resources are
                 wrapped in AshMultiDatalayer.DataLayer (an ETS cache in front
                 of AshRemote.DataLayer) AND subscribed to realtime
                 notifications. AshRemote.MultiDatalayer.ChangeNotifier +
                 AshRemote.MultiDatalayer.LifecycleGuard keep that cache correct
                 across clients. A second, LocalOutbox-backed resource stack
                 (TodoClient.Local.*) powers the offline-first /offline page.
```

## The flow

```
                     /auth/sign-in ──► JWT
todo_server ──/manifest.json──►  mix ash_remote.gen  ──►  TodoClient.Remote.{Todo,TodoList}
     ▲   ▲                                                     │  (wrapped in AshMultiDatalayer.DataLayer)
     │   └── ws /ash_remote/socket ◄── AshRemote.Realtime ◄─────┤        │
     │                                       │                  │        │
     │                     AshRemote.MultiDatalayer.ChangeNotifier       │
     │                     AshRemote.MultiDatalayer.LifecycleGuard        │
     └────────── /rpc/run (Bearer JWT) ◄── AshRemote.DataLayer ◄── AshMultiDatalayer ◄── TodoClient.Live
```

Every RPC and the realtime socket carry the signed-in user's JWT. The server
enforces owner-or-public policies on both reads and pushed notifications, so a
client only ever hears about (and can invalidate its cache for) rows it may see.

## What the utilities add: cross-client cache invalidation

`ash_multi_datalayer` caches reads locally (ETS in front of the remote data
layer) and shows hit/miss/backfill telemetry — but on its own only a client's
_own_ write path invalidates that cache. Nothing there reacts when a _different_
client's write arrives as a realtime notification. Two `ash_remote` utilities
close that gap (see their moduledocs for the full detail):

- **`AshRemote.MultiDatalayer.ChangeNotifier`** — an `Ash.Notifier`, listed
  FIRST in each generated resource's `notifiers:` (a literal list — see
  `AshRemote.MultiDatalayer`'s moduledoc for why it can't be built via a helper
  call). On every realtime-replicated change it routes the notification through
  the resource's `ash_multi_datalayer` orchestrator's `handle_external_change/2`
  — for these ProvenCoverage resources, that drops the coverage entries the row
  matches and physically evicts the row, so the next read is a genuine miss.
- **`AshRemote.MultiDatalayer.LifecycleGuard`** — a GenServer registered via
  `AshRemote.Realtime.listen_lifecycle/1`. Notifications are at-most-once, so a
  websocket disconnect can lose writes with nothing for the notifier above to
  react to; on `:resubscribed`/`:join_denied` it forwards to the orchestrator's
  `handle_external_gap/2` (ProvenCoverage drops the _entire_ ledger for the
  resource+tenant; LocalOutbox runs a full reconcile).

Both utilities are strategy-agnostic: they resolve the reaction from the
resource's own orchestrator, so the same two modules serve the online ETS-cache
resources and the offline LocalOutbox resources unchanged. The out-of-band
self-heal used by the `/` page (a cached row 404s against the backend with no
notification at all) calls `AshMultiDatalayer.forget!/3` /
`AshMultiDatalayer.not_found?/1` directly — MDL's public API.

## Run it

```sh
./run.sh   # both users, both demos — each client serves `/` and `/offline`
```

Open both pages (Ada + Grace). Each client instance serves two demos:

**`/` — the ProvenCoverage cache demo:**

1. On Grace's page, click through the Browse panel's status/priority tabs on one
   list. Watch the sticky cache bar: the first click on each filter is a
   miss+backfill, repeating it (or a narrower subset) is a pure hit.
2. On Ada's page, toggle or edit a todo Grace can see. Watch Grace's page
   refetch live — and her cache bar: exactly one new miss+backfill for the
   filter(s) that actually matched the changed row, `invalidations` incrementing
   by the dropped-entry count (not the full ledger), and any _other_ cached
   filter she'd warmed stays a hit.
3. Edit a **private** todo of Ada's that Grace can't see — the server's
   per-record channel authorization means Grace's page (and cache) don't change.
4. Kill `todo_server` briefly, make a change on Ada's side, then reconnect. The
   moment Grace's socket rejoins, her dashboard shows a full-ledger invalidation
   for that resource (not silently stale data), then fresh misses/backfills.
5. Add a **public** list/todo on either page → it appears live on both.

**`/offline` — the LocalOutbox demo:** toggle offline, edit local-first while
queued in the outbox, then go back online and resolve a stale-check conflict
with the three-way (Keep mine / Take theirs / Retry) UI. The `/oban` page shows
the outbox flush jobs draining.

## Automated tests

```sh
# the example client (in-BEAM, starts the backend in-process)
cd todo_client && mix test

# the ChangeNotifier/LifecycleGuard utilities themselves live in ash_remote:
cd ../.. && mix test
```

## Regenerate the client resources

```sh
cd todo_server && mix manifest.publish   # writes ../todo_client/priv/manifest.json
cd ../todo_client && mix remote.gen      # ash_remote.gen → lib/todo_client/remote/*
```

`mix remote.gen` overwrites `lib/todo_client/remote/{todo,todo_list}.ex`. Three
hand-edits must be re-applied afterward (each file says so in a comment): swap
`data_layer:` for `AshMultiDatalayer.DataLayer` + add the
`multi_data_layer do ... end` block, and put
`AshRemote.MultiDatalayer.ChangeNotifier` first in `notifiers:`.
`realtime?(true)` survives regeneration on its own — the manifest advertises it
because the server's domain configures `pub_sub`, so the generator sets it
automatically.
