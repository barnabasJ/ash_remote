import Config

# The generated client resources reach the backend via ash_remote; base_url is
# resolved lazily at call time so one build works across environments.
config :ash_remote, base_url: System.get_env("TODO_SERVER_URL", "http://127.0.0.1:4010")

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

# The in-BEAM end-to-end test runs the backend's RPC router in-process; a
# dependency's own config isn't loaded, so register its domains here for tests.
if config_env() == :test do
  config :todo_server, ash_domains: [TodoServer.Domain]
end

config :ash, :validate_domain_config_inclusion?, false
