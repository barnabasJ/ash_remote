defmodule TodoMob.MixProject do
  use Mix.Project

  def project do
    [
      app: :todo_mob,
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
        "ash_remote.gen --manifest priv/manifest.json --namespace TodoMob.Remote --output lib --yes"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TodoMob.Application, []}
    ]
  end

  defp deps do
    [
      # Same absolute path (with override) that ash_remote uses for ash, so
      # ash_phoenix's `ash ~> 3.0` requirement resolves against the local checkout.
      {:ash, path: "/home/joba/sandbox/ash", override: true},
      {:ash_phoenix, "~> 2.3"},
      {:ash_remote, path: "/home/joba/sandbox/ash_remote"},
      {:simple_sat, "~> 0.1"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},

      # The backend, only for the in-BEAM end-to-end test (starts its RPC router
      # via Bandit on localhost). Not needed to build or ship the client.
      {:todo_server, path: "../todo_server", only: :test, runtime: false}

      # In a real app, replace the in-repo `Mob` shim (lib/mob/) with the real
      # framework and deploy to a device/emulator:
      #   {:mob, "~> 0.7"}
      # then: mix mob.install && mix mob.deploy --native
    ]
  end
end
