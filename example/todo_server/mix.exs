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

  @manifest_path "../todo_mob/priv/manifest.json"

  defp aliases do
    [
      # Publish the RPC manifest (the contract artifact) into the client's priv/.
      "manifest.publish": &publish_manifest/1
    ]
  end

  defp publish_manifest(_args) do
    Mix.Task.run("compile")
    File.write!(@manifest_path, TodoServer.Rpc.Manifest.to_json())
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
      # Ash.Info.Manifest is an unreleased ash-core feature — path dep on the local checkout.
      {:ash, path: "/home/joba/sandbox/ash"},
      {:simple_sat, "~> 0.1"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
