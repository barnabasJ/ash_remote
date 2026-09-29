defmodule AshRemote.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_remote,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp aliases do
    [
      # `mix test` only runs this project's suite; the in-repo package under
      # packages/ash_cloner has its own. This runs both.
      "test.all": ["cmd --cd packages/ash_cloner mix test", "test"]
    ]
  end

  def cli do
    [preferred_envs: ["test.all": :test]]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Ash.Info.Manifest ships in ash core (>= 3.29).
      {:ash, "~> 3.29"},
      # The generic resource-cloning engine `mix ash_remote.gen` is built on
      # (definition contract + Igniter create/ensure/drift apply engine).
      # Developed in-repo; extracted so any package can ship cloneable resources.
      {:ash_cloner, path: "packages/ash_cloner"},
      {:igniter, "~> 0.6"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      # A SAT solver Ash needs at runtime (ash lists these as optional).
      {:simple_sat, "~> 0.1"},
      # Optional integration: the `AshRemote.MultiDatalayer.*` utilities compose an
      # ash_remote client with ash_multi_datalayer's local authority. Optional so
      # downstream apps that don't layer a local cache/store skip it entirely; the
      # utilities runtime-check MDL and raise clearly if invoked without it.
      {:ash_multi_datalayer, path: "../ash_multi_datalayer", optional: true},
      # Realtime transports — optional so downstream apps pull only their side
      # (server: phoenix + phoenix_pubsub; client: slipstream). Fetched here for
      # the library's own test suite (server socket/channel + client subscriber).
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:slipstream, "~> 1.1", optional: true},
      # `plug` backs the server Router macro (referenced only in its expansion)
      # and the reference backend. Optional so downstream client apps skip it;
      # made a plain optional dep (not `only:`) because the optional `phoenix`
      # dep pulls `plug` in all envs and an `:only` restriction diverges.
      {:plug, "~> 1.16", optional: true},
      # Reference-backend HTTP server (test/dev only).
      {:bandit, "~> 1.5", only: [:dev, :test]},
      # Spark.Formatter (mix format plugin, below) needs it to parse/patch source.
      # No `only:` restriction: ash_multi_datalayer already depends on it
      # unrestricted, and mix rejects divergent `only:` values for the same dep.
      {:sourceror, "~> 1.8"}
    ]
  end
end
