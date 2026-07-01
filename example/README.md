# ash_remote example — todo server + mob client

A two-project monorepo showing `ash_remote` end to end:

```
example/
  todo_server/   Ash backend. Exposes todos over the RPC protocol and publishes
                 a JSON Ash.Info.Manifest at /manifest.json.
  todo_mob/      A `mob` (BEAM-on-device) client. Consumes the manifest, generates
                 standalone Ash resources with `mix ash_remote.gen`, and manages
                 todos from a mob screen using AshPhoenix.Form — every read/write
                 is an RPC call to todo_server via AshRemote.DataLayer.
```

## The flow

```
todo_server ──/manifest.json──►  mix ash_remote.gen  ──►  TodoMob.Remote.{Todo,User,Priority}
     ▲                                                              │
     └──────── /rpc/run ◄──── AshRemote.DataLayer ◄──── TodoMob.TodoListScreen (AshPhoenix.Form)
```

The mob screen calls `Ash.read!/1`, `AshPhoenix.Form.submit/2`, `Ash.update/3`,
`Ash.destroy!/1` on the **generated** resources exactly as if they were local —
`AshRemote.DataLayer` turns each into an HTTP RPC call to `todo_server`.

## Run the automated end-to-end (no device needed)

`todo_mob`'s test boots the backend's RPC router in-process and drives the mob
screen headlessly (mount → create → toggle → delete), asserting each change made
a real round trip to the server:

```sh
cd todo_mob && HEX_OFFLINE=1 mix test
```

## Run the two-process demo

Boots `todo_server` as its own OS process, then runs the client demo against it:

```sh
./e2e.sh
```

(or manually: `cd todo_server && mix run --no-halt` in one shell, then
`cd todo_mob && mix run -e "TodoMob.Demo.run()"` in another.)

## Regenerate the client resources

```sh
# publish the manifest from the server
cd todo_server && mix run -e 'File.write!("../todo_mob/priv/manifest.json", TodoServer.Rpc.Manifest.to_json())'
# regenerate
cd ../todo_mob && mix ash_remote.gen --manifest priv/manifest.json --namespace TodoMob.Remote --output lib
```

## Running as a real mob app (device / emulator)

`mob` renders native SwiftUI / Jetpack Compose — there is no browser target, so a
real UI needs an iOS simulator or Android emulator. This example ships a small
in-repo `Mob` shim (`todo_mob/lib/mob/`) faithful to mob's `Mob.Screen` API so the
integration runs headlessly here. To run on a device, swap the shim for the real
framework — the screen code in `todo_mob/lib/todo_mob/` is unchanged:

```elixir
# todo_mob/mix.exs — remove lib/mob/ and add:
{:mob, "~> 0.7"}
```

```sh
mix mob.install
mix mob.deploy --native   # build + install to the simulator/emulator
```

> Note: these projects use local path deps to the sibling `ash` and `ash_remote`
> checkouts (`ash_remote`'s `Ash.Info.Manifest` is unreleased). In this sandbox,
> fetch deps with `HEX_OFFLINE=1 mix deps.get`.
