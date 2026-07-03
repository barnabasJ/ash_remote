import Config

# The reference backend domain is only compiled/registered in the test environment.
# `Ash.Info.Manifest.generate/1` discovers domains via `Ash.Info.domains(:ash_remote)`,
# which reads this config.
if config_env() == :test do
  config :ash_remote, ash_domains: [AshRemote.Backend.Domain]
end

config :ash, :validate_domain_config_inclusion?, false

# The `remote/1,2` custom expression (see AshRemote.Expressions.Remote). Ash reads
# `:custom_expressions` at compile time; downstream apps generating clients must
# register it too (the generator wires this).
config :ash, :custom_expressions, [AshRemote.Expressions.Remote]
