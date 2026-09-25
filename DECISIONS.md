# Decision log

## Naming

- Library is `ash_remote` (client), `AshRemote.*` namespace.

## Manifest source

- The rich structural manifest comes from **ash core** `Ash.Info.Manifest`
  (`generate/1`, `JsonSerializer.to_map/1`, `schema_version` `"1.0.0"`).
- It ships in released Ash (>= 3.29), so we use a normal hex dep
  `{:ash, "~> 3.29"}` — no path dep.

## Protocol

- We speak the `ash_typescript` RPC wire protocol (`/rpc/run`, `/rpc/validate`).
- **No `ash_typescript` dependency.** The server-side RPC core lives in
  `ash_remote` itself — `AshRemote.Server` + `AshRemote.Server.Router` (a
  `use`-able Plug router) — ported from ash_typescript and written so it can
  later be extracted into a shared package both `ash_typescript` and
  `ash_remote` depend on. A backend needs no custom RPC code:
  `use AshRemote.Server.Router, otp_app: :my_app`.
- Exposure is declared with the `AshRemote.Rpc` domain extension
  (`rpc do resource X do expose :action end end`), the ash_typescript-style
  counterpart.

## Architecture

- Decoupled / manifest-driven: generated resources depend only on `ash` +
  `ash_remote`.
- A custom `AshRemote.DataLayer` (implements `Ash.DataLayer`) translates
  queries/changesets into RPC calls. Actions on generated resources are
  **stubs** (server is authoritative).
- Capabilities (`can?/2`, filter/sort pushdown) are **derived from the
  manifest**, not a hand-written matrix (per-field
  `filter_operators`/`sortable?`).
- Igniter is used for non-destructive (re)generation.

## Wire encoding

- Actions are addressed by `{resource, action}` (both in the manifest), not an
  opaque RPC name — the manifest doesn't serialize one.
- `filter` uses Ash's `filter_input` map form; `sort` uses the `sort_input`
  string form; pagination is `{limit, offset}` (`offset: 0` is omitted as a
  no-op).
- Wire field names are snake_case by default (`AshRemote.Formatter` strategy
  `:none`); a `:camel` strategy is available for camelCasing backends.

## Manifest action-name gap (handled client-side)

- Ash's `JsonSerializer` (through at least 3.29.3) omits the action `name` from
  serialized entrypoints, so a JSON-only client couldn't tell which action to
  call. The `%Manifest{}` struct _does_ carry it, so
  `AshRemote.Server.manifest_json/1` builds the JSON from `to_map/1` and injects
  the action `name` into each entrypoint. No ash fork needed; a candidate
  upstream fix to `serialize_action/1`.

## Manifest relationship-attribute gap (handled the same way)

- The serializer also omits `source_attribute`/`destination_attribute` from
  relationships (and `Ash.Info.Manifest.Relationship` doesn't carry them at
  all), so the generator had to _guess_ FKs by naming convention — which breaks
  for `belongs_to :list` (FK `list_id`, not `todo_list_id`) and self-referential
  `has_many :subtasks`. `manifest_json/1` injects both attributes into each
  serialized relationship from the live resource, the loader parses them
  tolerantly (older manifests still load), and the generator emits them
  explicitly on every generated relationship. Candidate upstream fix to the
  manifest `Relationship` struct + serializer.

## Regeneration ownership model (no `managed_*` lists)

- The generator does not persist per-resource `managed_*` bookkeeping in the
  `remote` block. Ownership is defined by **manifest membership**, recomputed at
  regen time: entities the manifest declares are generator-owned; anything else
  in the file is user-added and ignored.
- `mix ash_remote.gen` implements this with the stock Igniter composition, not a
  bespoke diff engine: a module that doesn't exist is created whole; an existing
  module gains only the manifest entities it's missing, via
  `Ash.Resource.Igniter.add_new_attribute/ add_new_relationship/add_new_action`
  (+ `Ash.Domain.Igniter.add_resource_reference` for the domain). User edits to
  generated entities and user-added code are never touched, and regen with an
  unchanged manifest is a no-op (covered by `test/mix/ash_remote_gen_test.exs`).
- Drift is detected but never auto-resolved: an entity that _differs_ from the
  manifest (user edit, or the server changed it) and an entity _absent_ from the
  manifest (user-added, or the server removed it) are indistinguishable cases,
  so the task surfaces each as a warning by default; `--interactive` prompts per
  entity — keep the current version (the default answer) or take the manifest's
  (replace / remove). The same applies to stale `resource` references in the
  client domain.
- Upstream note: `Ash.Resource.Igniter.defines_calculation/3` (≤ 3.29.3) only
  matches arity-3 `calculate` calls, missing the `calculate ... do ... end` form
  — the task carries a corrected arity-3-or-4 check; candidate upstream fix.

## Validation mirroring (client-side validation without a round trip)

- Ash core's manifest serializes no validations, so
  `AshRemote.Server.manifest_json/1` publishes them itself (same augmentation
  channel as action names and relationship attributes): each resource gets a
  `"validations"` list of `{module, opts, on, where, message, only_when_valid}`
  entries.
- **Mirrorable** = builtin data-check module (allowlist in `server.ex`) + opts
  that round-trip as safe literals (`AshRemote.Literal`: inspect → parse →
  literal-only AST, with `{Spark.Regex, :cache, [...]}` as the single allowed
  call shape — how `~r//` is stored). `where` conditions are the same
  `{module, opts}` shape and mirror under the same recursive test — a `where`
  does NOT disqualify a validation. Function validations, custom modules, and
  non-literal opts are skipped: the server stays authoritative.
- Opts travel as Elixir source strings (JSON-safe, exact fidelity for
  atoms/keywords); the generator re-verifies module namespace + literal safety
  before emitting anything — a crafted manifest can't inject code into generated
  resources.
- Generated validations are rendered as the `Builtins` sugar the backend author
  wrote (`validate string_length(:title, min: 3)`, default `on:` omitted)
  whenever _calling the builtin reproduces the manifest opts exactly_
  (`AshRemote.Gen.Validations.sugar/2` — lossy rendering is impossible by
  construction); otherwise the `{Module, opts}` tuple form. Regen/drift compare
  by canonical identity (`identity/1`): sugar vs tuple form, option order, and
  `~r//` vs Spark's lazy regex tuple are all equivalent.
- Changes/lifecycle hooks remain server-only by construction (action stubs carry
  none); mirrored validations run on both sides — client for fast feedback,
  server for truth.
- Regen identity for validations is node equivalence (they have no name): a
  matching `validate` already exists → skip; an edited one is flagged as drift
  and the manifest version re-added.

## Reads with `limit` against non-paginated backend actions

- The client encodes query `limit`/`offset` as the wire `page` — but `Ash.get/2`
  reads with an internal `limit: 2`, and a backend read action without
  `pagination` enabled rejects page options. The server (`apply_page/3`) applies
  a plain limit/offset `page` as `Ash.Query.limit/offset` when the action has no
  pagination — the same read minus the page envelope; real pagination still goes
  through `Ash.Query.page/2`.

## Realtime replication

- Captured at the **notifier** level (`AshRemote.Server.Notifier`), not at RPC
  dispatch, so server-local writes replicate too and Ash's transaction/bulk
  deferral come free. The notifier broadcasts wire payloads via
  `pub_sub.broadcast/3` — the same contract as `Ash.Notifier.PubSub`'s `module`,
  so no compile-time Phoenix dependency.
- The client reconstructs a full `%Ash.Notifier.Notification{}` **including a
  synthetic changeset** (plain struct, never `for_*`) — required because
  `Ash.Notifier.PubSub` dereferences `changeset.resource`/`.to_tenant` for
  `:_pkey`/`:_tenant` topics.
- **Two-layer auth.** Join is a topic gate (default deny). Every broadcast is
  then checked per subscriber in the channel's `handle_out` — broadcasts fan out
  to all topic subscribers, so row-level read policies must be enforced there,
  not at broadcast time. Resources without authorizers skip it. _(Superseded
  mechanism, 2026-07-05: the original per-broadcast
  `Ash.can?({record, :read}, actor)` call was replaced with the ash_graphql
  approach — the actor's read-policy filter is computed once at join
  (`Ash.can(query, actor, run_queries?: false, alter_source?: true)`) and each
  notification is matched in-memory via `Ash.Expr.eval/2`, with a single
  authorized pk re-read as fallback, skipped for destroys.)_
- **Auth threading mirrors ash_typescript.** RPC resolves the actor from the
  conn via `Ash.PlugHelpers` (host plugs `ash_authentication`); the socket
  resolves it in the host's `connect/3`. Both run every action with that actor.
  The client forwards a token from the actor's metadata (auto Bearer header,
  propagates to relationship loads) or explicit context headers.
- Broadcast is best-effort (`try/rescue`): a realtime transport failure must
  never fail the originating write. Notifications are hints; reads are truth
  (at-most-once, no replay; `:resubscribed` is the refetch signal).
- Optional deps: `:phoenix`/`:phoenix_pubsub` (server), `:slipstream` (client),
  each guarded by `Code.ensure_loaded?/1` so a client-only app compiles without
  Phoenix.

## Composing with ash_multi_datalayer (2026-07-05/06)

- **PK-upsert as the LocalOutbox replication target.** `AshRemote.DataLayer`
  answers `can?(:upsert)` for pk-based upserts so `ash_multi_datalayer`'s
  LocalOutbox strategy can flush local-first writes to the backend idempotently
  under retries.
- **ash_remote_cache folded in.** Its lib dissolved into
  `AshRemote.MultiDatalayer.{ChangeNotifier, LifecycleGuard}` (optional
  `ash_multi_datalayer` dep); its example became `example/` here. The glue is
  strategy-agnostic: inbound realtime pushes route through the layered
  resource's orchestrator, lifecycle events become refresh/reconcile signals.
- **Source-map fan-out.** `Realtime` groups subscriptions by backend
  source/topic, so multiple client mirrors of one backend resource each react to
  a push (previously last-writer-wins in the source map dropped all but one).

## Whole-repo review fixes (2026-07-06)

- **Tenant travels on the wire, not just in the conn.** `Protocol.build_run`/
  `build_validate` gained an optional `"tenant"` key (absent = old wire shape,
  backward compatible); the client threads `query.tenant`/`changeset.to_tenant`
  through `run_query/2`, `write/5` (create/update), `destroy/2`, and
  `fetch_remote_calculations/4`. Server resolves wire-first, falling back to the
  conn's tenant. Explicitly documented as **input to Ash multitenancy, not an
  auth claim** — policies must still scope actors to tenants server-side.
  `validate_action/2` became `/3` (opts: actor/tenant) in the same change as
  threading the actor into it — the router's `/rpc/validate` call site changed
  in the same commit, since the two were independently broken in the same way
  (neither actor nor tenant reached the validate path at all).
- **No `Module.concat`/`String.to_atom` on wire input, anywhere.**
  `AshRemote.Server.ResourceResolver` precomputes a string→module map per
  `{otp_app, site}` (RPC exposure vs. realtime publications are different sets —
  separate cache keys, `:persistent_term`), used by both
  `Server.resolve_resource/2` and `Server.Channel.resolve_resource/2`.
  `AshMultiDatalayer.Orchestrator.LocalOutbox.HostResolver` (sibling repo)
  applies the same pattern for outbox entries. `Manifest.Loader.atom/2` moved
  from `String.to_atom/1` to `String.to_existing_atom/1` against an explicit,
  compile-time-primed vocabulary list (so load order elsewhere in the app never
  matters), naming the offending manifest key on failure.
- **Realtime field-policy stripping is server-computed, not per-subscriber.**
  `Server.Notifier` excludes policy-target fields (the fields a `field_policy`
  applies TO, not fields merely referenced by a policy condition) from both
  `payload/4`'s `"data"` and `changed/2`'s `"changed"` — computed once per
  notification from `Ash.Policy.Info.field_policies_for_field/2`. Chosen over
  per-subscriber evaluation for cost; a field-policied attribute never travels
  over realtime — load it via an authorized RPC read instead.
- **Transport errors are a typed Ash error.** `AshRemote.Error.Transport`
  (`Ash.Error.Unknown`-class) wraps `{:transport_error, _}` /
  `{:http_error, _, _}` in all four `request/4` call sites. Its `:unknown` class
  classifies `:transient` in `ash_multi_datalayer`'s `Flush.classify/1` (retry,
  then park) — the one cross-repo coupling in this fix round, landed together
  with that classifier's own `:auth` class for `Forbidden`. Also extended
  `Manifest.Error.to_exception/1` to map the wire type `"invalid_changes"` (what
  a server-side identity/uniqueness pre-check violation actually serializes as)
  to `Ash.Error.Changes.InvalidChanges` (`class: :invalid`) instead of falling
  through to the `:unknown` catch-all — needed so `upsert/3`'s collision
  detection (below) can key off `class: :invalid` the way the rest of the
  error-handling code already does.
- **`upsert/3`'s create-collision resolves to an update, once.** The
  read-then-write deciding create-vs-update is not atomic — two concurrent
  upserts for the same PK can both read `nil` and both attempt `create`; the
  loser now re-reads on a `:invalid`-class create failure and retries as an
  update instead of surfacing the collision. Does not close the window entirely
  (a third concurrent write between the retry's read and its update could still
  race) — a true fix needs a server-side identity upsert, filed as a follow-up
  against the protocol.
- **A durably-denied realtime topic is terminal for the socket process.**
  `Connection` tracks denied topics in process state (`handle_topic_close`'s
  `{:failed_to_join, _}` clause) and `handle_connect/1` excludes them from every
  subsequent rejoin; `:join_denied` fires once, not once per reconnect. The
  state resets only with the socket process itself — `connect_params` is
  evaluated once in `init/1` and reused for the process's lifetime (the previous
  "evaluated per connect" comment was wrong), so a durable denial cannot be
  un-denied without a fresh connection process (e.g. a supervisor restart with a
  new token).
- **`safe_message/1` keys off Splode's `.class`, not a module allowlist.**
  Mirrors `ash_json_api`'s `AshJsonApi.Error.to_json_api_errors/4` fallback
  branch: `error.class in [:invalid, :forbidden]` is safe to show verbatim
  (covers `Ash.Error.Invalid`, `Forbidden`, and every NotFound variant, all
  `class: :invalid`); everything else — critically `:unknown`, what a raised
  non-Ash exception becomes via `Ash.Error.to_error_class/1` — logs server-side
  with a correlation id and returns a generic message. A hardcoded module-name
  allowlist was tried first and missed `Ash.Error.Changes.InvalidChanges` (not
  literally `Ash.Error.Invalid`).
- **`ClientId.register/1` is idempotent.** Keeps the first id ever registered
  for a base_url instead of overwriting on every call — `:persistent_term.put/2`
  on an EXISTING key triggers a full VM-wide GC pass, so an unconditional
  overwrite on every supervisor restart was needless global cost, and would have
  changed the echo-correlation identity out from under in-flight requests. One
  `AshRemote.Realtime` supervisor per base_url remains the supported topology; a
  second registration for the same base_url logs once and shares the existing
  identity by design.
- **`Encode.Filter`'s `:applicable` gate deleted, not wired up.**
  `remote_config/1` never actually populated it (`applicable: nil`
  unconditionally), so the gate was permanently a no-op — the smaller, honest
  fix is deletion. The manifest data it would have gated on survives in the
  loader's normalized `filter_operators`/`filter_functions` for a future
  reintroduction, which would also need to extend the generator (it doesn't
  currently emit per-field operator info at all).

## Second-review fix run (2026-07-07/08)

- **A replicated write's accepted-keys filter excludes every `writable?: false`
  attribute, not just the primary key.** H2's original fix only excluded the PK
  from a replicated write's wire input (the field is addressed via the
  protocol's separate `primary_key` field, not as ordinary input). Found live
  while exercising the offline-first demo end-to-end: a LocalOutbox flush's
  hydrated snapshot carries every known attribute, including auto-managed
  `inserted_at`/`updated_at` — sent as wire input, the remote correctly rejects
  them ("is currently `writable?: false`"). Fixed by excluding every
  non-writable attribute the target resource declares, not only the PK.
- **`AshRemote.DataLayer.accepted_keys/1`'s replicated-write clause reads
  `changeset.resource`'s own attribute metadata**, not the manifest's. This is
  correct for a dedicated `AshRemote.DataLayer`-backed resource (its attributes
  mirror the remote's writability via codegen), but a multi-datalayer HOST
  resource (e.g. `ash_multi_datalayer`'s `TodoClient.Local.Todo`) has its own,
  independently-declared attribute writability — it must accurately mark
  hydration-only/display fields `writable?: false` itself for this filter to
  work. This is a real authoring responsibility for any multi-datalayer host
  resource wrapping `AshRemote.DataLayer` as a target layer, not something the
  library can infer on its own from the manifest.

## First real-backend integration (2026-07-17)

Generating client resources from a real, non-todo backend (arcc-center — see
its `mob/` sub-project) surfaced five gaps the reference backend's
Todo/User/Comment shape never exercised — the first three in codegen, the
last two in `AshRemote.DataLayer` itself (only caught once the generated
resource was actually *called* against a live backend, not just compiled;
added `Todo.by_status` — a non-primary read taking a real argument — plus an
e2e test to the reference backend so this class of bug has a live-wire
regression test going forward):

- **Loader `@known_atoms` was missing `:resource`, `:embedded_resource`,
  `:array`, `:any`, `:unknown`.** A backend field typed as an embedded
  resource (e.g. an `:address` struct attribute) has `type.kind ==
  :embedded_resource` in the manifest — `String.to_existing_atom/1` raised on
  it in a fresh VM that hadn't incidentally loaded `Ash.Info.Manifest.Type`
  (the only other place that literal atom appears), exactly the R-8 boot-order
  hazard the explicit list exists to close, just previously incomplete for
  these five kinds.
- **`gen_type/2` had no branch for `:embedded_resource`** — it fell through to
  the catch-all `subtype -> "use Ash.Type.NewType, subtype_of:
  #{inspect(subtype)}"`, emitting `subtype_of: :embedded_resource`, which
  isn't a valid NewType subtype and fails to compile. Fixed by adding a real
  branch: `AshRemote.Manifest.Type` now carries a `:resource` field (populated
  by the loader from the manifest's nested `type["resource"]`, reusing
  `normalize_resource/2` with an empty actions map — an embedded resource's
  own actions aren't needed for the generated mirror), and `gen_type/2`
  renders it as `use Ash.Resource, data_layer: :embedded` plus an `attributes
  do` block, reusing the same `attribute_fields/1`/`attribute_line/3` helpers
  `gen_resource/2` uses. No relationships/actions are rendered for an embedded
  mirror — it's a pure data container, cast as part of whatever parent
  attribute references it.
- **A `has_one`/`has_many`'s `destination_attribute` is not guaranteed present
  on the destination resource's own manifest entry.** The two sides of a
  relationship can be asymmetric in what's `public?` — an inverse `has_many`
  can be public while the owning `belongs_to`'s raw FK attribute isn't (and
  Ash's own manifest generator does not enforce symmetry here). Rendering the
  relationship anyway produces a `has_one`/`has_many` Ash's
  `ValidateRelationshipAttributes` verifier rejects at compile time — a
  generated-code compile failure with no non-destructive way to route around
  it by hand. Fixed by checking resolvability first (`destination_attribute`
  present either as a plain field or as some `belongs_to`'s
  `source_attribute` on the destination's own manifest entry) and rendering a
  `# Skipped :name (...)` comment instead when it isn't — the asymmetry lives
  in the source of truth, not something the generator should guess around.
- **Every generated resource now sets `primary_read_warning?: false`.**
  Generated actions are manifest-mirrored stubs, not hand-authored primary
  reads — Ash's "did you mean to put preparations on your primary read?"
  verifier warning is always a false positive for them (hit immediately on
  `User`, whose mirrored `:read` action carries validations).
- **`do_run_query/2` always resolved the resource's *primary* read action,
  ignoring whichever action `Ash.Query.for_read/3` actually selected.** Any
  resource whose real, exposed read isn't primary (the common case for a
  single purpose-built read like `by_session` rather than an unfiltered
  "list everything") either silently ran the wrong action or raised "has no
  primary read action" outright. `query.context.action` is the query's real
  selected action — populated by Ash's own generic pipeline, and already
  relied on by `get?/1` a few lines above the bug. `query_action_name/3`
  now prefers it, falling back to primary-action resolution (kept as
  `read_action_name/2`, still correct for `fetch_remote_calculations/5`'s
  PK-based bundle fetch, which genuinely wants "the primary read" regardless
  of the original query) only if unset.
- **A read action's caller-supplied argument *values* never reached the wire
  request at all** — only their static definition (names/types, via
  `context.action`) was ever visible to the data layer; the actual value a
  specific call supplied lives on `Ash.Query.arguments`, which no
  `Ash.DataLayer` callback receives directly. `transform_query/1` looked like
  the fix (the one callback given the full `Ash.Query.t()`) but fires at
  `Ash.Query.new/2`, before `for_read/4` casts any arguments — always empty
  there. Fixed with a new preparation, `AshRemote.CaptureArguments` (added to
  every generated read action, alongside the existing
  `AshRemote.PrefetchCalculations`), which runs after casting and stashes
  `query.arguments` into context for `do_run_query/2` to fold into the
  request's `input`.

## LocalOutbox flush against a real backend (2026-07-18)

Driving `Event`'s actual offline write→flush cycle against arcc-center for the
first time (rather than just compiling/reading the generated resource)
surfaced two more gaps in `AshRemote.DataLayer.upsert/3` — both masked by
every existing fixture (`RaceItem`, `Todo`) having a primary read *and* a
`primary?: true` create, which `Event`'s real shape (worker-scoped, so its
only read is non-primary/argument-gated; its create was never marked primary
because nothing about calling it by name needs that) doesn't share:

- **`remote_identity_row/3` unconditionally needs a primary read action** to
  dispatch its "does this row already exist remotely" lookup query — any
  resource with no primary read (the common, *correct* shape for a
  worker-scoped resource that must never expose an unfiltered list) crashed
  on every single upsert, i.e. every flush. Reordering `upsert/3` to always
  attempt `create` first (only reading on an actual collision) was
  considered and rejected — too broad a behavior change, and it would have
  broken `test/ash_remote/upsert_collision_test.exs` (R-7), which relies on
  the *current* read-first ordering to deterministically park a racer mid-
  lookup via `AshRemote.Test.RaceTransport`. Fixed narrowly instead: a new
  `server_upserts?` resource option (`AshRemote.Resource.Section`) — set on a
  resource whose remote `create` is already an idempotent upsert
  (`upsert_fields: []` on a client-supplied identity, e.g. arcc-center's real
  `Evv.Event.create`) — skips `remote_identity_row` entirely and dispatches
  straight to create. Defaults to `false`; every existing resource's
  behavior is unchanged.
- **`put_write_action/3` unconditionally called
  `Ash.Resource.Info.primary_action!(resource, :create | :update)`**, which
  raises unless an action of that type is explicitly `primary?: true` — a
  convention plenty of real resources don't follow when they have exactly
  one action of that type (arcc-center's real `Event.create`, notably).
  Fixed with `resolve_write_action!/2`: prefer the primary action if marked,
  fall back to the sole action of that type when unambiguous, only raise
  (the same message as before) when there's genuinely more than one and none
  is marked primary.

Both fixes are covered by `test/ash_remote/server_upserts_test.exs`, a
dedicated `UpsertOnly` backend+client fixture pair built to mirror `Event`'s
exact shape (non-primary-only read, non-primary create, `upsert_fields: []`)
so both bugs are exercised together, not just fixed in isolation. Verified
against mob_worker's real flush too: local SQLite write → outbox entry →
Oban worker → real row landing in arcc-center's Postgres, matched by
`client_event_id`.

## `Arcc.Scheduling.Session` realtime convergence, ProvenCoverage (2026-07-18)

Wiring a real ProvenCoverage-cached resource (`Session`, worker-scoped, no
mirrored admin-only write actions) into realtime for the first time surfaced
four more gaps, all in the realtime/serialization path rather than the
data-layer composition already exercised by `Event`/`LocalOutbox` above:

- **Wire dumping bypassed `Ash.Type`** — `Server.Fields.serialize/3` wrote
  attribute/calculation values with a bare `value/1` pass-through, which
  crashed (`Protocol.UndefinedError`) on any type without a `Jason.Encoder`
  impl (`AshScheduling.TimeRange`, then `Postgrex.Range` once that one was
  fixed client-side). Fixed by dumping every attribute/calculation through
  `Ash.Type.dump_to_embedded/3` (a new `value/2` + `field_type/2` type lookup)
  — the same JSON-safe path Ash's own JSON:API/GraphQL serializers use.
  Aggregates still pass through raw (no cheap static type available); this is
  an existing, narrower gap, not touched here.
- **Realtime subscriber visibility assumed the primary read action** —
  `Server.Channel.read_scope/3`/`refetch_visible?/4` hardcoded
  `Ash.Resource.Info.primary_action!(resource, :read)`, which for a
  worker-scoped resource whose primary read is admin-only/unscoped
  (`Session`) computes visibility as if every subscriber were an admin.
  Fixed with a new `realtime_read_action` `AshRemote.Rpc` DSL option
  (resource-level, alongside `expose`/`publish`) — when declared, both
  `read_scope/3` and `refetch_visible?/4` use it instead of the primary read;
  falls back to the primary read for every resource that doesn't declare one.
- **`Ash.can(query, actor, run_queries?: false, alter_source?: true)` collapses
  to a literal-`false` filter for a real, authorized actor** whenever a
  resource's read authorization combines a relationship-scoped `policy_group`
  with a separate, always-applying policy that itself needs a data-layer
  query to resolve (e.g. `actor_has_permission`, which needs `actor
  .permissions` loaded — a DB read `run_queries?: false` can't perform).
  Confirmed against `Session`'s real policy shape. Treating that answer as a
  genuine denial would silently and permanently black-hole realtime for every
  such actor. Fixed with a new `visible?/2` clause: a computed filter of
  literal `%Ash.Filter{expression: false}` falls back to the same
  per-notification authorized re-read already used for filters referencing
  data the wire payload doesn't carry, rather than being treated as settled.
- **`Realtime.Inbound.resolve_action/3` hard-skipped replication when no local
  action matched at all** (no action-map entry, no same-named action, no
  primary action of the matching type) — the correct, common shape for a
  worker-facing client mirror of a resource whose mutating actions are
  admin-only and deliberately never mirrored locally (`Session`'s `approve`/
  `decline`). This skipped calling `Ash.Notifier.notify/1` entirely, so
  `AshMultiDatalayer.Notifiers.ExternalChange` — which only ever reads
  `notification.data`/`notification.changeset.to_tenant` for both
  orchestrators' `handle_external_change/2`, never a genuinely resolved
  action beyond `Ash.Notifier.notify/1`'s own `.name`/`.type` bookkeeping —
  never ran, so a worker's local cache never invalidated on an admin-side
  approve/decline. Fixed by falling back to a synthetic, type-only action
  (`%Ash.Resource.Actions.{Create,Read,Update,Destroy}{name:
  :ash_remote_external_change}`) instead of skipping, when no real action
  resolves. Regression-guarded by
  `test/ash_remote/realtime_no_local_action_test.exs`, a client resource
  declaring only `:read` against a backend resource with `:update`.

Root-caused via the ProvenCoverage-specific chain end to end against a live
`mix phx.server` + `mix run --no-start` mob_worker client (Erlang distributed
nodes, so test code ran inside the real server process and reached real
websocket subscribers): approve a session as admin → notification pushed to
the worker's subscription → `Inbound.replicate/2` resolves a synthetic
`:update` action → `ExternalChange.notify/1` → `ProvenCoverage
.handle_external_change/2` invalidates the covered cache row.

## Wire-dumping a calc's raw value without normalizing it first (2026-07-18)

Building `mob/`'s first real LiveView screen against `Session` (loading
`derived_status`/`start_datetime`/`end_datetime` — three `remote(...)`-backed
calculations, the first time this session's real-backend work `Ash.Query
.load/2`ed any of them) surfaced a crash the type-aware dump fix earlier in
this file didn't catch: `Server.Fields.value/2` dumped a calculation's raw
value through `Ash.Type.dump_to_embedded/3` directly, on the (implicit)
assumption that a value reaching the wire serializer is already a canonical
instance of its declared type. True for an **attribute** (already ran through
`cast_stored/3` leaving the data layer), false for an **expression-based
calculation** backed by a raw DB fragment — it hands back whatever the driver
decoded verbatim. A `:utc_datetime`-declared calc backed by a Postgres
`timestamptz` (arcc-center's real `Session.start_datetime`/`end_datetime`)
always carries Ecto's internal `{0, 6}` microsecond-precision marker even
when every digit is zero; `Ecto.Type.dump/2` for `:utc_datetime` requires
literal `{0, 0}` and raises `ArgumentError` otherwise — surfaced end to end as
every `scheduled_between` RPC request failing with a sanitized "internal
error (id: ...)" (R-5's own server-side exception redaction correctly hid the
raw exception from the wire response, which is what made this take a
correlation-id round trip through arcc-center's own log to actually
diagnose).

Fixed by running the value through `Ash.Type.cast_input/3` — the same
normalization step Ash always applies to input — before dumping, falling
back to the raw value on a normalization miss rather than failing the field.
Applies uniformly to both attributes and calculations (idempotent for an
already-canonical attribute value, so no behavior change there).
Regression-guarded by `test/ash_remote/server/fields_test.exs` (a
`:utc_datetime`-typed calc value at `{0, 6}` and one already at `{0, 0}`,
both asserting no crash and correct ISO8601 JSON output).

## No transport seam for a generated resource (2026-07-18)

Setting up `mob/`'s Mox-based test strategy (per the project plan:
"`AshRemote.Transport` is the natural first candidate" for a behaviour-based
test seam) hit a real gap: `DataLayer.remote_config/1`'s generated-resource
branch (`remote do ... end`-DSL-declared, i.e. anything `mix ash_remote.gen`
produces) only ever returns `%{source:, base_url:, action_map:}` — no
`:transport` key. Only the *other*, older resource style (no `remote do end`
block, config supplied via `Application.get_env(:ash_remote, :remote_config)`
as a resource-keyed map) could ever set a custom transport, by putting it
directly in that map. A generated resource — every resource `mob/` actually
uses — had no seam at all to swap in a fake transport under test.

Fixed with a global `config :ash_remote, :transport_module` fallback that
every resource's default `Transport.Config.new/1` now picks up (mirroring the
existing `base_url` app-env fallback in the same function) — set it to a
`Mox.defmock(_, for: AshRemote.Transport)` module in `config/test.exs` and
every RPC call, from any resource, routes through it. Regression-guarded by
`test/ash_remote/transport_module_override_test.exs`: a plain hand-rolled
fake transport plus a deliberately-unreachable `base_url`, proving the real
transport is never attempted when the override is set.

## The resource-cloning engine extracted as `packages/ash_cloner` (2026-08-13)

`mix ash_remote.gen`'s apply machinery solved a problem bigger than
ash_remote: sharing Ash resources through packages is hard (which is why
core packages hand-write Igniter installers). It's now its own package,
`packages/ash_cloner` (plain nested mix project, path dep — not an
umbrella), so a library can write real, compilable, testable resources and
ship an installer that clones them into user apps.

What moved: the definition contract (`AshCloner.Definition` —
`%{module, kind, source, entities, resources}`, exactly the map
`AshRemote.Gen.generate/2` already returned, now a struct), the whole
create/ensure-missing/drift-reconcile engine from the mix task
(`AshCloner.apply_definitions/3` + `AshCloner.Engine`/`Engine.Drift`,
including the `defines_calculation` arity-[3,4] and domain
`add_resource_reference` upstream workarounds), the section/aggregate call
tables (`AshCloner.Sections` — previously triplicated), `common_prefix`
re-namespacing (`AshCloner.Namespace`), and `AshRemote.Gen.Validations`
verbatim (`AshCloner.Validations` — Ash-generic, nothing manifest-specific).
New in the package: `AshCloner.SourceCloner` (parse real resource source
from a dep, prefix-swap every `__aliases__` node, split into per-section
entities) and a generic `mix ash_cloner.clone` task.

What stayed: the manifest side (`Manifest.Loader`, `AshRemote.Gen`,
`Gen.Identifier` + `InvalidManifestError` — manifest trust is ash_remote's
concern; the engine takes already-validated definitions), and the task's
`output_path/2`/`assert_contained!/3` (directly tested against the manifest
error type; ash_cloner has its own copy raising `PathEscapeError`).

Two seams keep the extraction invisible to ash_remote's behavior, proven by
its gen tests passing **unmodified**: `apply_definitions`' `:labels` option
(`[definitions: "the manifest", upstream: "the server"]` reproduces the old
warning strings byte-for-byte) and `:path_for` (the task keeps its own
path/error semantics). Engine invariant worth preserving: it never touches
the filesystem — everything stages on the `Igniter.t()`, which is what makes
`--dry-run`/`--check` work for every task built on it.

The package shares the parent's `deps_path` and `mix.lock` (offline-safe
dev; must be unwound before hex publishing). `mix test.all` at the root
runs both suites.

## Versions

- Ash `~> 3.29` (hex, resolved 3.29.3). Elixir 1.18 / OTP 27.
- Realtime optional deps: `phoenix ~> 1.7`, `phoenix_pubsub ~> 2.1`,
  `slipstream ~> 1.1`.
- Composition optional deps: `ash_multi_datalayer` (path dep on the sibling
  repo), `plug ~> 1.16`.

## Root lock caught up to MDL's conservative inbound invalidation (2026-09-25)

The library's own `mix.lock` still pinned `ash_multi_datalayer` at `e0c0ed1`
(2026-07-06) while the example client had been bumped to `c7b07a5`
(2026-07-08, the tenant fix) — so `ash_remote`'s suite was proving
`ChangeNotifier` semantics against an MDL the demo no longer ran. Between
those two commits MDL's M3 fix changed what `ProvenCoverage
.handle_external_change/2` guarantees: `forget!/3` now probes the ledger with
a PK-only *unknown* row (an inbound change has no trustworthy local
before-image), and `Invalidation.should_drop?/3` treats an unknown evaluation
as a drop. MDL tried the precise variant and reverted it — it reintroduces the
stale-entry survival bug M3 closed (a covering entry whose filter neither the
unknown before- nor the known after-image matches survived) — and its
`handle_external_change/2` comment explicitly records the two ash_remote tests
that would fail as the accepted flip side.

Decision: bump the root lock to `c7b07a5` (what the example already runs) and
restate the contract in the tests rather than keep the library pinned to
semantics MDL abandoned:

- Guaranteed: every ledger entry the changed row matches is dropped and the
  row is physically evicted (the root test now asserts the eviction too —
  `CachedThing`'s two layers share one Ets store, so the row is simply gone).
- Guaranteed to survive: only an entry decidable from the PK alone, i.e. a
  point query on a *different* PK. An entry predicated on any non-PK field
  (`name == "bar"`, `status == :open`, `list_id == other`) is *not* guaranteed
  to survive — the old assertions that it would are gone from
  `AshRemote.MultiDatalayer.ChangeNotifierTest` and the example's
  `TodoClient.InvalidationWiringTest`.

The example README's "exactly one new miss+backfill for the filter(s) that
actually matched the changed row … any other cached filter she'd warmed stays
a hit" walkthrough describes the best case for PK-decidable coverage; a
filter on a non-PK field on the other client takes a miss on the next read
after any inbound change to that resource. Correctness (never a stale hit) is
what the utilities promise; MDL owns the precision trade-off.

Also in this pass: `TodoClient.Remote.{Todo,TodoList}` gained
`primary_read_warning?: false` (what `mix ash_remote.gen` emits since the
2026-07-17 entry above; the hand-edited example predated it and warned on
every compile), and `packages/ash_cloner` got its own `.gitignore` so its
`_build/` never lands in the repo.
