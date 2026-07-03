# Decision log

## Naming
- Library is `ash_remote` (client), `AshRemote.*` namespace.

## Manifest source
- The rich structural manifest comes from **ash core** `Ash.Info.Manifest`
  (`generate/1`, `JsonSerializer.to_map/1`, `schema_version` `"1.0.0"`).
- It ships in released Ash (>= 3.29), so we use a normal hex dep `{:ash, "~> 3.29"}` —
  no path dep.

## Protocol
- We speak the `ash_typescript` RPC wire protocol (`/rpc/run`, `/rpc/validate`).
- **No `ash_typescript` dependency.** The server-side RPC core lives in `ash_remote`
  itself — `AshRemote.Server` + `AshRemote.Server.Router` (a `use`-able Plug router) —
  ported from ash_typescript and written so it can later be extracted into a shared
  package both `ash_typescript` and `ash_remote` depend on. A backend needs no custom
  RPC code: `use AshRemote.Server.Router, otp_app: :my_app`.
- Exposure is declared with the `AshRemote.Rpc` domain extension (`rpc do resource X do
  expose :action end end`), the ash_typescript-style counterpart.

## Architecture
- Decoupled / manifest-driven: generated resources depend only on `ash` + `ash_remote`.
- A custom `AshRemote.DataLayer` (implements `Ash.DataLayer`) translates queries/changesets
  into RPC calls. Actions on generated resources are **stubs** (server is authoritative).
- Capabilities (`can?/2`, filter/sort pushdown) are **derived from the manifest**, not a
  hand-written matrix (per-field `filter_operators`/`sortable?`).
- Igniter is used for non-destructive (re)generation.

## Wire encoding
- Actions are addressed by `{resource, action}` (both in the manifest), not an opaque RPC
  name — the manifest doesn't serialize one.
- `filter` uses Ash's `filter_input` map form; `sort` uses the `sort_input` string form;
  pagination is `{limit, offset}` (`offset: 0` is omitted as a no-op).
- Wire field names are snake_case by default (`AshRemote.Formatter` strategy `:none`);
  a `:camel` strategy is available for camelCasing backends.

## Manifest action-name gap (handled client-side)
- Ash's `JsonSerializer` (through at least 3.29.3) omits the action `name` from serialized
  entrypoints, so a JSON-only client couldn't tell which action to call. The `%Manifest{}`
  struct *does* carry it, so `AshRemote.Server.manifest_json/1` builds the JSON from
  `to_map/1` and injects the action `name` into each entrypoint. No ash fork needed; a
  candidate upstream fix to `serialize_action/1`.

## Manifest relationship-attribute gap (handled the same way)
- The serializer also omits `source_attribute`/`destination_attribute` from relationships
  (and `Ash.Info.Manifest.Relationship` doesn't carry them at all), so the generator had
  to *guess* FKs by naming convention — which breaks for `belongs_to :list` (FK `list_id`,
  not `todo_list_id`) and self-referential `has_many :subtasks`. `manifest_json/1` injects
  both attributes into each serialized relationship from the live resource, the loader
  parses them tolerantly (older manifests still load), and the generator emits them
  explicitly on every generated relationship. Candidate upstream fix to the manifest
  `Relationship` struct + serializer.

## Regeneration ownership model (no `managed_*` lists)
- The generator does not persist per-resource `managed_*` bookkeeping in the `remote` block.
  Ownership is defined by **manifest membership**, recomputed at regen time: entities the
  manifest declares are generator-owned; anything else in the file is user-added and ignored.
- `mix ash_remote.gen` implements this with the stock Igniter composition, not a bespoke
  diff engine: a module that doesn't exist is created whole; an existing module gains only
  the manifest entities it's missing, via `Ash.Resource.Igniter.add_new_attribute/
  add_new_relationship/add_new_action` (+ `Ash.Domain.Igniter.add_resource_reference` for
  the domain). User edits to generated entities and user-added code are never touched, and
  regen with an unchanged manifest is a no-op (covered by `test/mix/ash_remote_gen_test.exs`).
- Drift is detected but never auto-resolved: an entity that *differs* from the manifest
  (user edit, or the server changed it) and an entity *absent* from the manifest
  (user-added, or the server removed it) are indistinguishable cases, so the task
  surfaces each as a warning by default; `--interactive` prompts per entity — keep the
  current version (the default answer) or take the manifest's (replace / remove). The
  same applies to stale `resource` references in the client domain.
- Upstream note: `Ash.Resource.Igniter.defines_calculation/3` (≤ 3.29.3) only matches
  arity-3 `calculate` calls, missing the `calculate ... do ... end` form — the task carries
  a corrected arity-3-or-4 check; candidate upstream fix.

## Validation mirroring (client-side validation without a round trip)
- Ash core's manifest serializes no validations, so `AshRemote.Server.manifest_json/1`
  publishes them itself (same augmentation channel as action names and relationship
  attributes): each resource gets a `"validations"` list of `{module, opts, on, where,
  message, only_when_valid}` entries.
- **Mirrorable** = builtin data-check module (allowlist in `server.ex`) + opts that
  round-trip as safe literals (`AshRemote.Literal`: inspect → parse → literal-only AST,
  with `{Spark.Regex, :cache, [...]}` as the single allowed call shape — how `~r//` is
  stored). `where` conditions are the same `{module, opts}` shape and mirror under the
  same recursive test — a `where` does NOT disqualify a validation. Function validations,
  custom modules, and non-literal opts are skipped: the server stays authoritative.
- Opts travel as Elixir source strings (JSON-safe, exact fidelity for atoms/keywords);
  the generator re-verifies module namespace + literal safety before emitting anything —
  a crafted manifest can't inject code into generated resources.
- Generated validations are rendered as the `Builtins` sugar the backend author wrote
  (`validate string_length(:title, min: 3)`, default `on:` omitted) whenever *calling the
  builtin reproduces the manifest opts exactly* (`AshRemote.Gen.Validations.sugar/2` —
  lossy rendering is impossible by construction); otherwise the `{Module, opts}` tuple
  form. Regen/drift compare by canonical identity (`identity/1`): sugar vs tuple form,
  option order, and `~r//` vs Spark's lazy regex tuple are all equivalent.
- Changes/lifecycle hooks remain server-only by construction (action stubs carry none);
  mirrored validations run on both sides — client for fast feedback, server for truth.
- Regen identity for validations is node equivalence (they have no name): a matching
  `validate` already exists → skip; an edited one is flagged as drift and the manifest
  version re-added.

## Reads with `limit` against non-paginated backend actions
- The client encodes query `limit`/`offset` as the wire `page` — but `Ash.get/2` reads
  with an internal `limit: 2`, and a backend read action without `pagination` enabled
  rejects page options. The server (`apply_page/3`) applies a plain limit/offset `page`
  as `Ash.Query.limit/offset` when the action has no pagination — the same read minus
  the page envelope; real pagination still goes through `Ash.Query.page/2`.

## Versions
- Ash `~> 3.29` (hex, resolved 3.29.3). Elixir 1.18 / OTP 27.
