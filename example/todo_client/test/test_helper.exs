# Boot the backend (auth + RPC) in-process, wrapped in a counting plug (the
# multi-datalayer proof tests assert exact server request counts — "the
# second read made zero RPCs"), so the end-to-end tests drive the real
# generated client resources against a real HTTP server without a detached
# process.
{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Application.ensure_all_started(:ash)
{:ok, _} = Application.ensure_all_started(:ash_authentication)

TodoClient.Test.CountingRouter.install_counter!()

port = 4996
{:ok, _} = Bandit.start_link(plug: TodoClient.Test.CountingRouter, port: port, startup_log: false)
Application.put_env(:ash_remote, :base_url, "http://127.0.0.1:#{port}")

# The backend's PubSub + endpoint, so AshRemote.Server.Notifier's broadcasts
# land somewhere (no subscribers) rather than warning.
{:ok, _} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: TodoServer.PubSub}, TodoServer.Endpoint],
    strategy: :one_for_one
  )

# Register the demo user this instance signs in as (TodoClient.Session
# defaults to ada@example.com / password123), then start the client's
# cache/session/pubsub trees (start_children: false in test config skips the
# realtime websocket — that's exercised live in a browser, see the example
# README, since two independent cache instances need two real OS processes).
{:ok, _} =
  Req.post("http://127.0.0.1:#{port}/auth/register",
    json: %{email: "ada@example.com", password: "password123"}
  )

{:ok, _} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: TodoClient.PubSub},
      AshMultiDatalayer.Supervisor,
      TodoClient.CacheStats
    ],
    strategy: :one_for_one
  )

{:ok, _} = TodoClient.Session.start_link([])

ExUnit.start()
