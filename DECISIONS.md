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

## Versions
- Ash `~> 3.29` (hex, resolved 3.29.3). Elixir 1.18 / OTP 27.
