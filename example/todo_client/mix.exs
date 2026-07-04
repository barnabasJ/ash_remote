defmodule TodoClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :todo_client,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp aliases do
    [
      # Generate the standalone client resources from the published manifest.
      "remote.gen": [
        "ash_remote.gen --manifest priv/manifest.json --namespace TodoClient.Remote --output lib --yes"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TodoClient.Application, []}
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.29"},
      {:ash_phoenix, "~> 2.3"},
      {:ash_remote, path: "../.."},
      {:simple_sat, "~> 0.1"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      # The realtime client transport (server→client push).
      {:slipstream, "~> 1.1"},

      # A small, viewable LiveView UI over the generated resources.
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.0"},
      {:bandit, "~> 1.5"},

      # The backend, only for the in-BEAM end-to-end test (starts its RPC router
      # via Bandit on localhost). Not needed to build or ship the client.
      {:todo_server, path: "../todo_server", only: :test, runtime: false}
    ]
  end
end
