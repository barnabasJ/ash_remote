# Decision log

## Naming
- Library is `ash_remote` (client), `AshRemote.*` namespace.

## Manifest source
- The rich structural manifest comes from **ash core** `Ash.Info.Manifest`
  (`generate/1` + `JsonSerializer.to_json/2`, `schema_version` `"1.0.0"`).
- `Ash.Info.Manifest` is unreleased, so we depend on the local ash checkout via a
  **path dep** (`/home/joba/sandbox/ash`) until it lands in a hex release.

## Protocol
- We speak the `ash_typescript` RPC wire protocol (`/rpc/run`, `/rpc/validate`).
- **No `ash_typescript` dependency.** The server-side pipeline/controller is *copied in
  as a template* under `test/support/backend/rpc/`, written dependency-free so the shared
  protocol core can later be extracted into a package both `ash_typescript` and
  `ash_remote` depend on.

## Architecture
- Decoupled / manifest-driven: generated resources depend only on `ash` + `ash_remote`.
- A custom `AshRemote.DataLayer` (implements `Ash.DataLayer`) translates queries/changesets
  into RPC calls. Actions on generated resources are **stubs** (server is authoritative).
- Capabilities (`can?/2`, filter/sort pushdown) are **derived from the manifest**, not a
  hand-written matrix (per-field `filter_operators`/`sortable?`).
- Igniter is used for non-destructive (re)generation.

## Wire encoding
- `filter` uses Ash's `filter_input` map form; `sort` uses the `sort_input` string form;
  pagination is `{limit, offset, keyset}`.
- Field names are camelCased on the wire by default; `AshRemote.Formatter` maps
  snake_case ⇄ camelCase on the client, mirrored server-side.

## Upstream change to ash core (local checkout)
- `Ash.Info.Manifest.JsonSerializer.serialize_action/1` omitted the action `name`,
  so a client consuming the JSON manifest could not know which action to call.
  Added `"name" => to_string(action.name)` to the serialized action in the local
  ash checkout (`lib/ash/info/manifest/json_serializer.ex`). This is the
  manifest↔protocol seam fix and is a candidate upstream contribution.

## Versions
- Ash 3.29.1 (path dep). Elixir 1.18 / OTP 27.
