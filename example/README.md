# ash_remote example — authenticated realtime todos

A two-project monorepo showing `ash_remote` end to end: **authenticated RPC over
HTTP**, **realtime replication over a websocket**, and **per-record
authorization** — all wired to `ash_authentication`.

```
example/
  todo_server/   The auth authority AND resource/realtime server, on one Phoenix
                 endpoint. ash_authentication issues JWTs; Todo/TodoList are
                 owned by the signed-in user (owner-only, or public); the domain
                 exposes them over RPC and publishes changes with AshRemote.Server.Notifier.
  todo_client/   A LiveView app. Consumes the manifest, generates standalone Ash
                 resources with `mix ash_remote.gen`, signs in for a JWT, and shows
                 the user's todos live — reads/writes over authenticated RPC,
                 updates over the realtime socket.
```

## The flow

```
                     /auth/sign-in ──► JWT
todo_server ──/manifest.json──►  mix ash_remote.gen  ──►  TodoClient.Remote.{Todo,TodoList}
     ▲   ▲                                                         │        │
     │   └── ws /ash_remote/socket ◄── AshRemote.Realtime ◄────────┘        │
     └────────── /rpc/run (Bearer JWT) ◄── AshRemote.DataLayer ◄── TodoClient.Live
```

Every RPC carries the user's JWT (auto-forwarded from the actor); the realtime
socket authenticates with the same JWT. The server runs each action as that
user, so both reads and pushed notifications are scoped by the resource's
policies.

## What it demonstrates

- **Authentication (ash_authentication).** `todo_server` owns users (email +
  password, JWT tokens). `TodoServer.AuthPlug` turns a Bearer token into an
  actor for RPC; `TodoServer.RemoteSocket` does the same from a connect param
  for realtime — RPC and subscriptions authenticate identically.
- **Owner filtering.** `Todo`/`TodoList` have an owner-only read policy, so a
  user only sees their own private items — enforced on RPC **and** on realtime
  delivery (the channel re-checks `Ash.can?({record, :read}, actor)` before
  pushing).
- **Public sharing.** A `public` flag flips the policy to "own it OR it's
  public", so public todos are visible to everyone and their changes broadcast
  to all clients.
- **Realtime.** `AshRemote.Realtime` re-emits each server-side change locally; a
  `RealtimeBridge` notifier forwards it to the LiveView, which refetches. You
  only receive changes you're allowed to see.
- **Token ergonomics.** The client passes a `CurrentUser` actor carrying the JWT
  in metadata; `AshRemote.DataLayer` auto-forwards it as a Bearer header —
  including on Ash's relationship-load follow-up reads.

## Run it (two users, live)

```sh
# 1) the server (auth + RPC + socket on http://localhost:4010)
cd example/todo_server && mix run --no-halt
#    seeds ada@example.com and grace@example.com (password: password123)

# 2) client instance A — Ada, at http://localhost:4001
cd example/todo_client && WEB_PORT=4001 TODO_EMAIL=ada@example.com mix run --no-halt

# 3) client instance B — Grace, at http://localhost:4002
cd example/todo_client && WEB_PORT=4002 TODO_EMAIL=grace@example.com mix run --no-halt
```

Open both pages. Then:

- Add a **private** todo in Ada's page → it appears for Ada only; Grace never
  sees it.
- Add a **public** todo (tick the box) in either page → it appears in **both**,
  live.
- Toggle/delete a public todo in one page → the other updates live.

The server console can drive it too: an
`Ash.create!(TodoServer.Todo, %{…, public: true}, actor: user)` shows up in
every client immediately.

## Automated end-to-end test (no browser)

```sh
cd example/todo_client && mix test
```

## Regenerate the client resources

```sh
cd todo_server && mix manifest.publish   # writes ../todo_client/priv/manifest.json
cd ../todo_client && mix remote.gen      # ash_remote.gen → lib/todo_client/remote/*
```

The manifest advertises a `realtime` block, so generated resources gain
`realtime? true` automatically. Regeneration is non-destructive; add
`--interactive` to resolve drift.

> `ash`/`ash_authentication` come from Hex; `ash_remote` is a relative path dep
> (`../..`).
