import Config

config :todo_server, token_signing_secret: "v0Wbw83GnwSwz0jk7pkA4Cb60+1LogiA"

config :todo_server, TodoServer.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4010"))],
  server: true,
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: TodoServer.PubSub,
  secret_key_base: String.duplicate("todo_server_demo_secret_key_base_", 2),
  render_errors: [formats: [json: TodoServer.ErrorJSON], layout: false],
  debug_errors: true

config :phoenix, :json_library, Jason
