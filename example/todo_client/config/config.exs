import Config

# The generated client resources reach the backend via ash_remote; base_url is
# resolved lazily at call time so one build works across environments.
config :ash_remote, base_url: System.get_env("TODO_SERVER_URL", "http://127.0.0.1:4010")
config :ash_remote, transport_module: TodoClient.Remote.Transport

# The client layers an ETS cache over the remote data layer via
# ash_multi_datalayer. v1 is single-node-only; this acknowledges it.
config :ash_multi_datalayer, :assume_single_node, true

# This local demo opts into human-readable row labels in read telemetry.
# The library emits none unless an application supplies a labeler.
config :ash_multi_datalayer, :telemetry_row_labeler, {TodoClient.CacheStats, :row_label, []}

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
config :ash, :default_string_length_count, :codepoints

# The generated `remote(...)` calcs use ash_remote's custom expression; a
# downstream app generating clients must register it (compile-time).
config :ash, :custom_expressions, [AshRemote.Expressions.Remote]

# Configure the DSL auto-formatter (`mix ash.install`'s default): strip the
# excess parens Spark DSL calls don't need, and sort resource/domain sections
# for consistency.
config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [
        :resources,
        :policies,
        :authorization,
        :domain,
        :execution
      ]
    ]
  ]

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts this app into the new behavior and
# ensures a seamless upgrade. See the backwards compatibility guide for an
# explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true
