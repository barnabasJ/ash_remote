{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = AshRemote.Backend.TestBackend.start()

# Realtime test infrastructure: a PubSub and the websocket-only Phoenix endpoint
# (port 4748) that mounts AshRemote.Backend.RemoteSocket. The Bandit HTTP backend
# on 4747 is untouched.
{:ok, _} = Application.ensure_all_started(:phoenix)

{:ok, _} =
  Supervisor.start_link([{Phoenix.PubSub, name: AshRemote.Backend.PubSub}],
    strategy: :one_for_one
  )

{:ok, _} = AshRemote.Backend.Endpoint.start_link()

ExUnit.start()
