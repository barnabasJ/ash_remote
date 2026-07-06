import Config

# The generated client resources reach the backend via ash_remote; base_url is
# resolved lazily at call time so one build works across environments.
config :ash_remote, base_url: System.get_env("TODO_SERVER_URL", "http://127.0.0.1:4010")

# The client layers an ETS cache over the remote data layer via
# ash_multi_datalayer. v1 is single-node-only; this acknowledges it.
config :ash_multi_datalayer, :assume_single_node, true

# Log every RPC the client makes (URL, resource/action, outcome, duration,
# request/response bodies) — Ecto-style visibility into the wire traffic.
# Off under test only to keep test output readable.
config :ash_remote, debug_requests: config_env() != :test

config :todo_client,
  ash_domains: [TodoClient.Remote.Domain, TodoClient.Sync, TodoClient.Local]

# The LocalOutbox stack: a per-instance SQLite file (override TODO_DB_PATH to run
# two isolated instances), carrying local_todos + outbox_entries + oban_jobs.
config :todo_client, ecto_repos: [TodoClient.Repo]

config :todo_client, TodoClient.Repo,
  database: System.get_env("TODO_DB_PATH", "priv/todo_client_dev.db"),
  pool_size: 1,
  journal_mode: :wal

# Oban Lite (SQLite engine) drains the outbox `:todo_sync` queue. Sweeping is
# MDL-owned, so no cron schedules here.
config :todo_client, Oban,
  engine: Oban.Engines.Lite,
  repo: TodoClient.Repo,
  queues: [todo_sync: 5],
  plugins: [{Oban.Plugins.Cron, crontab: []}]

# Background outbox flushes run in an Oban worker with no request actor. This MFA
# supplies the signed-in instance's JWT (as an explicit Bearer header) to every
# target-layer read/write ash_multi_datalayer performs on the app's behalf, so
# the server authenticates the flush as this instance's user. See
# `AshMultiDatalayer.RemoteContext` and `TodoClient.Session.remote_context/0`.
config :ash_multi_datalayer, :remote_context, {TodoClient.Session, :remote_context, []}

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

  config :bcrypt_elixir, log_rounds: 1
  config :logger, level: :warning

  # Under test, don't run flush jobs automatically — drive them explicitly.
  config :todo_client, Oban, testing: :manual
end

config :ash, :validate_domain_config_inclusion?, false

# The generated `remote(...)` calcs use ash_remote's custom expression; a
# downstream app generating clients must register it (compile-time).
config :ash, :custom_expressions, [AshRemote.Expressions.Remote]
