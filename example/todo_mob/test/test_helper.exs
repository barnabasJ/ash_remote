# Boot the backend's RPC router in-process (same BEAM) so the end-to-end test
# drives the mob screen against a real HTTP server without a detached process.
{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Application.ensure_all_started(:ash)

port = 4998
{:ok, _} = Bandit.start_link(plug: TodoServer.Rpc.Router, port: port, startup_log: false)
Application.put_env(:ash_remote, :base_url, "http://127.0.0.1:#{port}")

ExUnit.start()
