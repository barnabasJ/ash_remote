# ash_remote — Implementation Plan

An Elixir **client** for the `ash_typescript` RPC protocol. The backend publishes a
versioned `Ash.Info.Manifest` JSON artifact scoped to its RPC-exposed actions. A mix
task consumes that manifest and generates **standalone** Ash resources (data parts
mirrored, actions are stubs) backed by an `AshRemote.DataLayer` that speaks
`/rpc/run` and `/rpc/validate`. Generated resources depend only on `ash` + `ash_remote`
and compile in any Ash app. Igniter keeps regeneration non-destructive.

---

## Current status

The phase checklists below are the **original plan**. This section records what is
actually built. Tests: `mix test` → 1 doctest + 53 tests green; the example client
(`example/todo_client`) → 2 e2e tests green.

| Phase | State | Notes |
|-------|-------|-------|
| 0 Foundations & spikes | ✅ done | Reference backend (`test/support/backend`), committed manifest + protocol fixtures. |
| 1 Transport & protocol | ✅ done | `AshRemote.Transport{,.Req}`, `AshRemote.Protocol`, `AshRemote.Error`, `AshRemote.Formatter`. |
| 2 Encoding core | 🟡 partial | `Encode.{Fields,Filter,Sort,Pagination}`. Filter covers the common operators (`==`,`!=`,`in`,`<`,`>`,`<=`,`>=`,`is_nil`) — others raise; unsupported operators aren't gated by `can?` yet, so they raise at build time. Capability **gating exists but isn't auto-populated** from the manifest's per-field `filter_operators` (the `:applicable` option is always nil today). Pagination is offset/limit only (no count/keyset request from the client). |
| 3 Data layer (walking skeleton) | 🟡 **partial** | Full CRUD + loads round-trip. **Calcs/aggregates fold into one `/rpc/run`; relationships do NOT** — they use Ash's batched separate reads (one `/rpc/run` per relationship, not per row). Single-round-trip relationship folding is **not yet done**. `:transact` → false; bulk → not implemented. |
| 4 Resource extension & Info | ✅ done | `AshRemote.Resource` (`remote do … end`) + Info + verifier. schema_version verifier is basic (presence, not deep compat). |
| 5 Manifest ingestion | ✅ done | `AshRemote.Manifest.Loader` + own structs, version-validated. |
| 6 Code generation | ✅ done | `mix ash_remote.gen` (one `Gen` module, not split files): enums/NewTypes, attrs, calc/agg stubs, relationships, action stubs, `remote` block. **Generic actions not generated.** `--check`/`--dry-run` via Igniter. |
| 7 Igniter regeneration | ❌ not built | `managed_*` lists are **emitted but unused** — the diff-aware reconciler isn't written; regen overwrites. |
| 8 Auth/multitenancy/config | ❌ not built | Lazy `base_url` config done; token/actor/tenant propagation and CSRF not done. |
| 9 Installer, docs, examples | 🟡 partial | Example monorepo built (`example/`): `todo_server` + a **LiveView** `todo_client`. `mix igniter.install` and full docs not done. |
| 10 Hardening & upstream | ❌ not built | Bulk N-call, keyset edge cases, Channel transport, shared-core extraction pending. |

### Deviations from the original plan (all deliberate)

- **`Ash.Info.Manifest` is ash core, not ash_typescript** — and it's in released Ash
  (>= 3.29), so it's a normal hex dep `{:ash, "~> 3.29"}` (no path dep). Ash's JSON
  serializer omits the action `name`, so `AshRemote.Server.manifest_json/1` injects it
  from the `%Manifest{}` struct (see `DECISIONS.md`) — a candidate upstream contribution.
- **No `ash_typescript` dependency.** The RPC *server* core was ported into `ash_remote`
  itself — `AshRemote.Server` + `AshRemote.Server.Router` (a `use`-able Plug router) — so a
  backend needs no custom RPC code. This is the "shared core" the plan slated for later
  extraction (Phase 10).
- **Exposure DSL:** `AshRemote.Rpc` — an ash_typescript-style `rpc do resource X do expose
  :action end end` block; the server + published manifest derive the exposed surface from it.
- **Action addressing:** the wire identifies actions by `{resource, action}` (both in the
  manifest) rather than an opaque RPC name (the manifest doesn't serialize one).
- **No manual actions.** Ash skips the data layer for a no-change update and resets
  `context.changed?` before commit, so a no-input custom action (e.g. `complete`) can't
  round-trip from an Ash client. The idiomatic path — change the attribute (`update
  completed: true`) — is used instead. This is a known limitation of an Ash-on-the-client.
- **Example client is LiveView, not `mob`.** `mob` renders native UI (no browser) and isn't
  fetchable offline; the example ships a viewable LiveView over the same generated resources.

### Biggest open item

Single-round-trip **relationship** loading (Phase 3's "one round-trip"). It's not reachable
via the data-layer callbacks (`transform_query` sees `load: []`; Ash strips relationship loads
before the fetch). The feasible path is a read **preparation** that captures the load subtree,
strips relationships so Ash's loader no-ops, folds the tree into the nested wire `fields`, and
populates it on decode — with a fallback for relationship loads carrying their own
filter/sort/limit.

---

## Guiding principles

- **Walking skeleton first.** Get a *hand-written* mirror resource round-tripping against a
  live backend before writing any codegen. Codegen just emits what you already proved works.
- **Pure core, thin IO.** Protocol/field/filter/sort encoding are pure functions, unit-tested
  without a network. Transport and the data layer wrap them.
- **Derive, don't hand-maintain.** Capabilities (`can?`, filter/sort pushdown) come from the
  manifest, not a hand-written matrix.
- **One round-trip.** Calc and aggregate loads fold into the single `/rpc/run` field
  selection. (Relationship loads currently use Ash's batched separate reads — one request per
  relationship, not per row; single-request folding is the biggest open item, see status above.)
- **Server is authoritative.** Client changes/validations are optional and additive; the real
  casting, authorization, and transaction happen server-side. Generated types are *structural
  stand-ins*, not behavioral clones.

---

## Target module / directory layout

```
lib/ash_remote/
  transport/
    transport.ex            # AshRemote.Transport behaviour
    req.ex                  # AshRemote.Transport.Req (default)
  protocol.ex               # build/parse /rpc/run & /rpc/validate bodies (pure)
  error.ex                  # wire errors -> Ash.Error.*
  encode/
    fields.ex               # Ash load -> nested `fields`
    filter.ex               # Ash.Filter -> wire filter (+ capability gating)
    sort.ex                 # sort -> wire (+ capability gating)
    pagination.ex           # offset/keyset -> page params
  data_layer.ex             # AshRemote.DataLayer (implements Ash.DataLayer)
  query.ex                  # AshRemote.Query accumulator struct
  resource.ex               # AshRemote.Resource extension (DSL)
  resource/info.ex          # AshRemote.Resource.Info introspection
  resource/transformers/    # verify mappings, pk/identities, schema_version
  manifest/
    loader.ex               # load + validate + normalize manifest JSON
    structs.ex              # AshRemote.Manifest.{Resource,Field,Type,...}
  gen/
    generator.ex            # manifest -> module source (Igniter)
    resource_gen.ex
    type_gen.ex
    domain_gen.ex
lib/mix/tasks/ash_remote.gen.ex
```

---

## Phase 0 — Foundations & de-risking spikes

Establish the fixtures everything else is tested against. Do not skip the spikes; the manifest
and protocol shapes are under-documented and you want samples committed.

- [ ] `mix new ash_remote` (lib, not supervised). Add deps: `ash`, `igniter`, `req` (or `finch`),
      `jason`. Dev/test: an inline **reference backend** app under `test/support/backend/`.
- [ ] Build the reference backend: a small Ash + `ash_typescript` app with resources that exercise
      the hard cases — a `Todo` (belongs_to `User`, has_many `Comment`), an **enum** attribute, a
      **NewType** attribute, a **calculation** (with and without an argument), and an **aggregate**.
      Mount the `/rpc/run` and `/rpc/validate` endpoints and the `typescript_rpc` (soon `ash_remote`)
      exposure block.
- [ ] **Spike A (manifest):** call `Ash.Info.Manifest.generate(otp_app: :backend, action_entrypoints: [...])`
      with the exposed `{resource, action}` tuples; serialize to JSON. Commit the sample to
      `test/support/fixtures/manifest.json`. Write a short note documenting the actual shapes of
      `resources`, `types`, `filter_capabilities`, `sort_capabilities`, and the per-field applicable
      operator/function lists (docs are terse — record what's really there).
- [ ] **Spike B (protocol):** hand-craft raw `Req` calls to `/rpc/run` for read, read-with-nested-fields,
      create, update, destroy, and a validate call. Capture request bodies, success responses, and
      error responses (invalid input, forbidden, not found). Commit to
      `test/support/fixtures/protocol/`.
- [ ] Start a `DECISIONS.md` decision log (naming = `ash_remote`; reuse ash_typescript protocol;
      decoupled/manifest-driven; data layer; stubs-only actions; Igniter section-patching).

**Done when:** running backend + committed manifest sample + committed request/response/error samples.

---

## Phase 1 — Transport & protocol (the wire layer)

- [ ] Define `AshRemote.Transport` behaviour: `request(config, body) :: {:ok, map} | {:error, term}`.
      Config carries `base_url`, `run_path`, `validate_path`, header injection, timeouts, retries.
- [ ] Implement `AshRemote.Transport.Req` as the default.
- [ ] `AshRemote.Protocol` (pure): `build_run/1`, `build_validate/1` from
      `%{action, fields, input, filter, sort, page}`; `parse_run/1`, `parse_validate/1` from responses.
      No HTTP here.
- [ ] `AshRemote.Error`: map wire error payloads to `Ash.Error.Invalid` / `Forbidden` / `NotFound` /
      `Framework`, preserving field paths and messages so validation errors round-trip usefully.
- [ ] Tests: unit tests for build/parse/error against Phase 0 samples (no network). Integration tests
      hitting the live backend behind an `@tag :integration`.

**Done when:** you can call a backend action through raw protocol functions and get typed `Ash.Error`s.

---

## Phase 2 — Encoding core (Ash query → wire)

The semantic heart. Kept separate so both the data layer and validate path reuse it, and so it's
testable with capabilities passed in as plain args.

- [ ] `AshRemote.Encode.Fields`: Ash load statement (attributes + nested relationship loads + calcs
      with args) → the protocol's nested `fields` selection (`["id", "title", {user: ["name"]}]`).
- [ ] `AshRemote.Encode.Filter`: `Ash.Filter`/`Ash.Query` filter → wire filter encoding. **Gate against
      capabilities**: if an operator/function/custom-expression isn't in the field's applicable list,
      raise a clear, actionable error rather than silently over-fetching.
- [ ] `AshRemote.Encode.Sort`: sort → wire, gated by `sort_capabilities`.
- [ ] `AshRemote.Encode.Pagination`: offset and keyset → page params.
- [ ] Tests: representative Ash filters → expected JSON; each unsupported construct → descriptive error;
      nested field/calc-arg selection round-trips.

**Done when:** given an `Ash.Query`, you produce a correct `/rpc/run` body, and unsupported constructs
fail loudly.

---

## Phase 3 — The data layer (walking skeleton milestone)

- [ ] Read the current `Ash.DataLayer` behaviour docs and **pin the exact callback names/arities**
      against the installed Ash version before implementing (they evolve).
- [ ] `AshRemote.Query` accumulator struct (resource, filter, sort, limit, offset, loads, calcs, aggregates).
- [ ] Implement `AshRemote.DataLayer`:
  - [ ] `can?/2` — derived from capabilities: `:read/:create/:update/:destroy`, filter/sort/limit/offset
        flags, per-operator `{:filter_expr, ...}`, `distinct` if supported, `:transact` → **false**,
        bulk callbacks → false (or naive N-call) for now.
  - [ ] Query-building callbacks: `resource_to_query`, `filter`, `sort`, `limit`, `offset`,
        `add_calculation`, `add_aggregate` — each folds into `AshRemote.Query`.
  - [ ] `run_query` — encode fields/filter/sort/page (Phase 2), call transport, decode.
  - [ ] `create` / `update` / `destroy` — map changeset → action name + input, call transport, decode.
  - [ ] Decode: JSON → resource structs honoring the requested selection; set `__meta__`, primary key,
        loaded relationships and calcs.
  - [ ] Fold relationship + calc loads into the field selection (single round-trip).
- [ ] Config/mapping access: temporarily hard-code transport config + action mapping + capabilities on a
      hand-written mirror resource (the extension arrives in Phase 4).
- [ ] Tests: hand-written mirror resource → read / filter / sort / paginate / load rel / load calc(+arg) /
      load aggregate / create / update / destroy, all against the live backend.

**Done when:** a **hand-written** resource on `AshRemote.DataLayer` round-trips all CRUD + loads. The
runtime is proven before codegen exists.

---

## Phase 4 — Resource extension & Info

- [ ] `AshRemote.Resource` extension with a `remote do ... end` DSL section holding: transport/config
      reference, action → remote-action-name mapping, per-field/filter/sort **capabilities** (compiled
      from the manifest at gen time and embedded), `schema_version`, and a `source_hash`.
- [ ] `AshRemote.Resource.Info`: `remote_action/2`, `capabilities/1`, `schema_version/1`, etc. — the data
      layer reads everything from here (remove the Phase 3 hard-coding).
- [ ] Transformers/verifiers: every mapped action resolves; primary key + identities present;
      **schema_version compatibility verifier** that errors at compile time on incompatible manifests.
- [ ] Client config resolution: `base_url`/headers/token strategy via app env / `runtime.exs`, resolved
      **lazily at call time** so one generated codebase works across environments.
- [ ] Tests: extension compiles; Info returns expected data; verifier catches a missing mapping and a
      version mismatch.

**Done when:** the Phase 3 hand-written resource is re-expressed with the extension, and the data layer
sources all config from Info.

---

## Phase 5 — Manifest ingestion

- [ ] `AshRemote.Manifest.Loader`: load JSON from a file path **or** URL; validate `schema_version`
      first; decode into your **own** normalized structs (`AshRemote.Manifest.*`) — do not depend on
      Ash's manifest structs being present, since the client may run a different Ash version. Be tolerant
      of unknown fields.
- [ ] Normalize: resources (attributes vs calcs vs aggregates, relationships, identities, primary key,
      actions + arg schemas), named types (enums/newtypes with constraints), capabilities (top-level +
      per-field).
- [ ] Tests: load the Phase 0 sample; assert the normalized model matches the backend.

**Done when:** manifest JSON → an in-memory model the generator can consume, with version validation.

---

## Phase 6 — Code generation (fully generated milestone)

- [ ] `mix ash_remote.gen` (Igniter task). Options: `--manifest <path|url>`, `--output <dir>`,
      `--namespace <Module.Prefix>`, `--domain <Module>`, `--check`, `--dry-run`.
- [ ] `AshRemote.Gen.TypeGen`: each named type → an `Ash.Type.Enum` / NewType module with matching
      values/constraints. Idempotent, own directory.
- [ ] `AshRemote.Gen.ResourceGen`: each resource →
  - [ ] `use Ash.Resource, data_layer: AshRemote.DataLayer, extensions: [AshRemote.Resource]`
  - [ ] attributes (types incl. generated type refs, constraints, `public?`, primary key)
  - [ ] calculations & aggregates as **loadable fields** with arg schemas
  - [ ] relationships pointing at the other generated modules
  - [ ] identities + primary key
  - [ ] **action stubs** — name/type + accepted args from the manifest, **no** changes/validations
  - [ ] the `remote` block (action mapping, embedded capabilities, `schema_version`, `source_hash`)
  - [ ] mark the generated DSL regions for Phase 7 (managed-entity tracking, e.g. `managed_fields [...]`).
- [ ] `AshRemote.Gen.DomainGen`: generate/patch a client domain listing the resources (+ optional code
      interface).
- [ ] Wire the task into `mix ash.codegen`; support `--check` (non-zero exit when stale) and `--dry-run`.
- [ ] Tests: generate against the sample manifest → **compile** the output in a fixture app → run the
      full loop (backend → manifest → generate → call generated resource → data over the wire) and assert
      parity with the Phase 3 hand-written results.

**Done when:** `mix ash_remote.gen` emits standalone, compiling resources that behave identically to the
hand-written ones against the live backend.

---

## Phase 7 — Igniter intelligent regeneration

- [ ] Make the generator diff-aware. For an existing generated module, locate each managed DSL section
      via zipper and reconcile **only generator-owned entities** by name (add new, update changed, remove
      ones dropped from the manifest) while never touching user-added actions, changes, preparations,
      helpers, or extra code.
- [ ] Track generator ownership (the `managed_*` lists in the `remote` block) so "user added this
      attribute" is distinguishable from "generator added it and it's now gone."
- [ ] Handle: `schema_version` bump (warn/refuse), field rename (delete+add, or a rename map),
      removed exposed action (drop the stub unless the user customized it → then warn, don't clobber).
- [ ] Tests: generate → hand-edit (add a custom action + a client-side change + a helper fn) →
      regenerate with a changed manifest (add attr, remove attr, change a type) → assert user edits
      survive and managed sections updated. Assert idempotency when the manifest is unchanged.

**Done when:** regeneration preserves user code, reconciles managed sections correctly, and is a no-op
when nothing changed.

---

## Phase 8 — Auth, multitenancy, config ergonomics

- [ ] Token/actor: client holds a token; transport attaches it as a header. Configurable strategy
      (static / per-call opts / callback). The actor struct is **never** serialized — the backend derives
      the actor and runs its own policies.
- [ ] Multitenancy: map `tenant` → header/param; generated resources declare a multitenancy strategy
      matching the backend when tenancy is exposed.
- [ ] CSRF support for session-authed Phoenix backends (mirror ash_typescript's token helper).
- [ ] Per-environment config resolution finalized (base_url etc. lazy at call time).
- [ ] Tests: token propagation, tenant propagation, forbidden → `Ash.Error.Forbidden`.

**Done when:** auth and tenancy propagate correctly and map to proper Ash errors.

---

## Phase 9 — Installer, docs, examples

- [ ] `mix igniter.install ash_remote`: add dep, scaffold config, drop a sample `ash_remote.gen`
      invocation, optional `--from-url` bootstrap.
- [ ] Docs: getting started; the **contract-publication workflow** (backend emits a versioned manifest
      artifact — served and/or written in CI; client consumes it and runs `--check` in CI); capability
      limitations; the "generated types are structural stand-ins" caveat; the generated-vs-custom code
      boundary rules.
- [ ] Example repo: reference backend + a decoupled client app consuming the published manifest.

**Done when:** a new user can install, point at a manifest, generate, and call a resource by following
the docs.

---

## Phase 10 — Hardening & upstream

- [ ] Pagination edge cases (keyset cursors, count strategies), large-list behavior.
- [ ] Bulk actions: document the N-call fallback semantics, or add a backend batch endpoint later.
- [ ] Alternate transport: Phoenix Channel / WebSocket (`ash_typescript` supports channel RPC) as a
      second `AshRemote.Transport`.
- [ ] Extract the shared server/protocol core with `ash_typescript` upstream (the "extract later" goal).
- [ ] Upstream proposal: RPC endpoint's accepted filter/sort encodings **derive from / validate against**
      the manifest capabilities, so there's one source of truth and the manifest↔protocol seam can't drift.

---

## Milestone summary (dependency order)

1. **M0** Fixtures ready (Phase 0)
2. **M1** Raw protocol round-trips with typed errors (Phases 1–2)
3. **M2 — walking skeleton:** hand-written resource does full CRUD + loads over RPC (Phase 3)
4. **M3** Extension + Info; config sourced declaratively (Phase 4)
5. **M4** Manifest ingested and normalized (Phase 5)
6. **M5 — fully generated:** generated resources compile and behave identically (Phase 6)
7. **M6** Non-destructive regeneration (Phase 7)
8. **M7** Auth/tenancy, installer, docs, examples (Phases 8–9)
9. **M8** Hardening + upstreaming (Phase 10)

---

## Testing strategy

- **Unit** (no network, the majority): protocol build/parse, error mapping, field/filter/sort/pagination
  encoding, manifest normalization, generator output shape. Drive from committed fixtures.
- **Integration** (`@tag :integration`): everything against the live reference backend — raw protocol,
  data-layer CRUD, generated-resource parity.
- **Compile test:** generated output must compile in a fixture app that depends only on `ash` +
  `ash_remote` — this is the guard for the "standalone / compiles anywhere" requirement.
- **Regeneration test:** hand-edit generated code, regenerate against a mutated manifest, assert user
  code survives and managed sections update; assert idempotency on an unchanged manifest.

---

## Open decisions still to pin

- **Generated resource layout details:** one module per resource confirmed — but exact namespace
  convention, where user code is expected to live, and whether the code interface is generated onto the
  domain.
- **Manifest delivery for decoupled apps:** committed artifact in the client repo vs. fetched from a
  backend endpoint at gen time (or both). Affects the installer and CI recipe.
- **Rename handling:** rely on delete+add, or invest in a manifest-level rename/stable-id map to preserve
  user references across field renames.
- **Bulk semantics:** N-call fallback now vs. wait for a backend batch endpoint.
- **The manifest↔protocol alignment seam** — the one real risk. Worth raising with Zach early given the
  intent to extract a shared core anyway.
