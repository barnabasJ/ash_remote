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

## Versions

- Ash `~> 3.29` (hex, resolved 3.29.3). Elixir 1.18 / OTP 27.
- Realtime optional deps: `phoenix ~> 1.7`, `phoenix_pubsub ~> 2.1`,
  `slipstream ~> 1.1`.
- Composition optional deps: `ash_multi_datalayer` (path dep on the sibling
  repo), `plug ~> 1.16`.
