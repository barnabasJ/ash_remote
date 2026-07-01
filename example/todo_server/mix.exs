defmodule TodoServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :todo_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
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
