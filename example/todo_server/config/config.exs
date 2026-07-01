import Config

config :todo_server,
  ash_domains: [TodoServer.Domain],
  port: String.to_integer(System.get_env("PORT", "4010"))

config :ash, :validate_domain_config_inclusion?, false
