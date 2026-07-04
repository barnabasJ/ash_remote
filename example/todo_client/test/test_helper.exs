# Boot the backend (auth + RPC) in-process so the end-to-end test drives the
# authenticated LiveView against a real HTTP server without a detached process.
{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Application.ensure_all_started(:ash)
{:ok, _} = Application.ensure_all_started(:ash_authentication)

port = 4998
{:ok, _} = Bandit.start_link(plug: TodoServer.WebRouter, port: port, startup_log: false)
Application.put_env(:ash_remote, :base_url, "http://127.0.0.1:#{port}")

# The backend's PubSub + endpoint, so AshRemote.Server.Notifier's broadcasts land
# somewhere (no subscribers) rather than warning.
{:ok, _} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: TodoServer.PubSub}, TodoServer.Endpoint],
    strategy: :one_for_one
  )

# Register the demo user this instance signs in as, then start the client session
# (which signs in for a JWT) and PubSub for the LiveView.
{:ok, _} =
  Req.post("http://127.0.0.1:#{port}/auth/register",
    json: %{email: "ada@example.com", password: "password123"}
  )

{:ok, _} =
  Supervisor.start_link([{Phoenix.PubSub, name: TodoClient.PubSub}], strategy: :one_for_one)

{:ok, _} = TodoClient.Session.start_link([])

ExUnit.start()
