# Realtime handoff

## Where the plan lives

The full implementation plan for the realtime/notification-replication feature is
checked in **outside this repo**, at:

```
/home/joba/alembic/.claude/plans/we-need-to-have-deep-pizza.md
```

That file is the source of truth for scope, design, and sequencing. This document
is just a pointer plus the state of the world at handoff time — read the plan
before writing any code.

## One-paragraph summary of the plan

Server resources attach a new `AshRemote.Server.Notifier` (a plain `Ash.Notifier`)
that broadcasts wire-shaped payloads for exposed/opted-in mutation actions over a
Phoenix Endpoint configured in the `rpc` DSL (`pub_sub` option), gated by
`publish`/`no_publish` entries (opt-out always wins). A new
`AshRemote.Server.Socket`/`Channel` pair (Phoenix, optional dep, guarded by
`Code.ensure_loaded?/1`) is mounted by the host app; channel join is the
authorization gate (default deny — hosts implement `authorize_subscription/4`).
On the client, a new `AshRemote.Realtime` supervisor holds one Slipstream
connection per `base_url`, auto-joins a topic per `realtime? true` remote
resource, decodes pushed payloads through a newly-extracted `AshRemote.Decoder`,
reconstructs a full `%Ash.Notifier.Notification{}` **including a synthetic
changeset** (required — `Ash.Notifier.PubSub` dereferences
`notification.changeset.resource`/`.to_tenant` for `:_pkey`/`:_tenant` topics),
suppresses echoes of the client's own writes by default, and calls
`Ash.Notifier.notify/1` — so ordinary client-side notifiers (e.g.
`Ash.Notifier.PubSub` → LiveView) fire as if the mutation were local. Topic shape:
`ash_remote:<source>[:<tenant>]`. HTTP `/rpc/run` stays the call path;
this only adds server→client push. The plan's acceptance scenario: one
`todo_server` + two `todo_client` instances (`WEB_PORT=4001` / `4002`) against it —
mutating a todo in either browser page (or from the server console) updates
the other page live.

## Status at handoff

- Design is fully approved (two independent Plan-agent passes reconciled: a
  pragmatic minimal-surface design and a deep-integration/notification-fidelity
  design). No implementation has started yet.
- Baseline: `mix test` is green — **92 tests passing** — before any realtime code
  lands. Re-check this baseline first if you're picking this up cold.
- The plan's "Implementation order" section (11 numbered steps) is the intended
  sequence: decoder extraction (pure refactor) → topics → DSL → server notifier →
  socket/channel → echo plumbing → client resource flag → client runtime → e2e
  tests → manifest/codegen → example apps → docs. Each step should leave
  `mix test` green before moving to the next, especially step 1 (the decoder
  extraction must not change behavior — it's a refactor, not a feature).

## Key existing files a future implementer should read first

- `lib/ash_remote/rpc.ex` + `lib/ash_remote/rpc/info.ex` — the domain-level `rpc`
  DSL being extended with `pub_sub`/`publish`/`no_publish`.
- `lib/ash_remote/resource.ex` — the `remote do ... end` resource section gaining
  `realtime?`.
- `lib/ash_remote/server.ex` — `entrypoints/1` (pattern for the new
  `publications/1`), `dispatch/3` (bang calls — notifications already flow to
  whatever notifiers a resource declares, they're just never transported today).
- `lib/ash_remote/server/fields.ex` — `Fields.serialize/3`, reused for
  notification payloads.
- `lib/ash_remote/data_layer.ex` — private `decode_record/3`/`cast_attribute/3`/
  `write_fields/1` and `config/1`, which the plan extracts into
  `AshRemote.Decoder` and publicizes as `remote_config/1`.
- `test/support/backend/` and `test/support/client/` — the in-process
  Bandit-backed test harness the realtime tests extend (new Phoenix endpoint on
  port 4748, alongside the existing HTTP backend on 4747 — do not disturb it).
- `example/todo_server/` and `example/todo_client/` — where the two-browser
  acceptance demo gets wired up last.
- `DECISIONS.md` and `ash_remote_implementation_plan.md` — existing decision log
  and phase-status doc for the rest of the library; Phase 10 of the latter
  already flagged a channel transport as unbuilt/aspirational, which this work
  fulfills (for subscriptions; RPC-over-socket is explicitly out of scope for v1
  per the plan).

## Notes / gotchas called out in the plan

- Ash notifiers are resource-level but the `rpc` exposure DSL is domain-level —
  the notifier resolves the domain via `notification.domain || Ash.Resource.Info.domain/1`.
- Bulk actions default `notify?: false`, so bulk writes silently won't replicate
  unless callers opt in.
- Client tenant string must match the server's `to_tenant` string; RPC calls
  don't send tenant on the wire yet (pre-existing gap, not fixed by this work,
  just documented).
- Hex registry can be unreliable in this sandbox — if `mix deps.get` for the new
  optional deps (`phoenix`, `phoenix_pubsub`, `slipstream`) times out, retry
  before assuming something is broken.
