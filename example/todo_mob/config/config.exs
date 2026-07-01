import Config

# The generated client resources reach the backend via ash_remote; base_url is
# resolved lazily at call time so one build works across environments.
config :ash_remote, base_url: System.get_env("TODO_SERVER_URL", "http://127.0.0.1:4010")

config :todo_mob, ash_domains: [TodoMob.Remote.Domain]

config :ash, :validate_domain_config_inclusion?, false
