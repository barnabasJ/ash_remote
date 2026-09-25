import Config

# Configure the DSL auto-formatter (`mix ash.install`'s default): strip the
# excess parens Spark DSL calls don't need, and sort resource/domain sections
# for consistency. `:authentication, :token, :user_identity` (ash_authentication's
# own sections) are kept after the standard Ash.Resource order.
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
        :identities,
        :authentication,
        :token,
        :user_identity
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

config :todo_server,
  ash_domains: [TodoServer.Accounts, TodoServer.Domain],
  port: String.to_integer(System.get_env("PORT", "4010"))

config :ash, :validate_domain_config_inclusion?, false

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

import_config "#{config_env()}.exs"
