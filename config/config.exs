import Config

# The reference backend domain is only compiled/registered in the test environment.
# `Ash.Info.Manifest.generate/1` discovers domains via `Ash.Info.domains(:ash_remote)`,
# which reads this config.
if config_env() == :test do
  config :ash_remote,
    ash_domains: [
      AshRemote.Backend.Domain,
      AshRemote.Backend.SecureDomain,
      AshRemote.Backend.WhenRequestedDomain
    ]

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
