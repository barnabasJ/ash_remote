import Config

config :spark,
  formatter: ["Ash.Resource": [section_order: [:authentication, :token, :user_identity]]]

config :todo_server,
  ash_domains: [TodoServer.Accounts, TodoServer.Domain],
  port: String.to_integer(System.get_env("PORT", "4010"))

config :ash, :validate_domain_config_inclusion?, false
import_config "#{config_env()}.exs"
