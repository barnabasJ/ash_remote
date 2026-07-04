defmodule TodoServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :todo_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  @manifest_path "../todo_client/priv/manifest.json"

  defp aliases do
    [
      # Publish the RPC manifest (the contract artifact) into the client's priv/.
      "manifest.publish": &publish_manifest/1
    ]
  end

  defp publish_manifest(_args) do
    Mix.Task.run("compile")
    File.write!(@manifest_path, AshRemote.Server.manifest_json(:todo_server))
    Mix.shell().info("wrote #{@manifest_path}")
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TodoServer.Application, []}
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.29"},
      # ash_remote provides the server-side RPC router + manifest (the shared core).
      {:ash_remote, path: "../.."},
      # Igniter powers the ash_authentication installer/codegen.
      {:igniter, "~> 0.6"},
      # Authentication authority: users, password strategy, JWT tokens. Verified
      # on both the RPC plug and the realtime socket connect.
      {:ash_authentication, "~> 4.0"},
      {:bcrypt_elixir, "~> 3.0"},
      {:simple_sat, "~> 0.1"},
      # Phoenix hosts the realtime socket (and, via Bandit.PhoenixAdapter, the RPC
      # routes) on a single port.
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
