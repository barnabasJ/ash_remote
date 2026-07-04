import Config

# The generated client resources reach the backend via ash_remote; base_url is
# resolved lazily at call time so one build works across environments.
config :ash_remote, base_url: System.get_env("TODO_SERVER_URL", "http://127.0.0.1:4010")

# Log every RPC the client makes (URL, resource/action, outcome, duration,
# request/response bodies) — Ecto-style visibility into the wire traffic.
# Off under test only to keep test output readable.
config :ash_remote, debug_requests: config_env() != :test

config :todo_client, ash_domains: [TodoClient.Remote.Domain]

# Minimal LiveView endpoint. Started by the app supervision tree; it opens a
# port whenever the app runs (e.g. `mix run --no-halt`) but not under `mix test`.
config :todo_client, TodoClient.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("WEB_PORT", "4001"))],
  secret_key_base: String.duplicate("todo_client_secret_key_base_0123", 2),
  live_view: [signing_salt: "todocli0"],
  pubsub_server: TodoClient.PubSub,
  check_origin: false,
  debug_errors: true,
  server: config_env() != :test

config :phoenix, :json_library, Jason

# The in-BEAM end-to-end test runs the backend (auth + RPC) in-process; a
# dependency's own config isn't loaded, so register its domains + token secret here.
if config_env() == :test do
  config :todo_server,
    ash_domains: [TodoServer.Accounts, TodoServer.Domain],
    token_signing_secret: "todo_client_e2e_token_signing_secret_change_me"

  # The e2e harness starts the backend + session manually (test/test_helper.exs);
  # don't auto-start the client's realtime tree (it would connect before the
  # in-process server exists).
  config :todo_client, start_children: false

  # The backend endpoint (no HTTP port) so the notifier's broadcasts have a
  # pubsub to land on instead of warning.
  config :todo_server, TodoServer.Endpoint,
    adapter: Bandit.PhoenixAdapter,
    secret_key_base: String.duplicate("todo_server_test_secret_key_base_", 2),
    pubsub_server: TodoServer.PubSub,
    server: false
end

config :ash, :validate_domain_config_inclusion?, false
