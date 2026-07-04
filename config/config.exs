import Config

# The reference backend domain is only compiled/registered in the test environment.
# `Ash.Info.Manifest.generate/1` discovers domains via `Ash.Info.domains(:ash_remote)`,
# which reads this config.
if config_env() == :test do
  config :ash_remote, ash_domains: [AshRemote.Backend.Domain, AshRemote.Backend.SecureDomain]

  # Websocket-only Phoenix endpoint for the realtime tests, alongside the Bandit
  # HTTP reference backend on 4747 (do not disturb that). Started by
  # test/test_helper.exs together with its PubSub.
  config :ash_remote, AshRemote.Backend.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 4748],
    server: true,
    secret_key_base: String.duplicate("ash_remote_test_secret", 3),
    pubsub_server: AshRemote.Backend.PubSub,
    adapter: Bandit.PhoenixAdapter
end

config :ash, :validate_domain_config_inclusion?, false

# The `remote/1,2` custom expression (see AshRemote.Expressions.Remote). Ash reads
# `:custom_expressions` at compile time; downstream apps generating clients must
# register it too (the generator wires this).
config :ash, :custom_expressions, [AshRemote.Expressions.Remote]
