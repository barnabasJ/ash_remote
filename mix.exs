defmodule AshRemote.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_remote,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
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
      {:igniter, "~> 0.6"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      # A SAT solver Ash needs at runtime (ash lists these as optional).
      {:simple_sat, "~> 0.1"},
      # Reference-backend HTTP server (test/dev only).
      {:plug, "~> 1.16", only: [:dev, :test]},
      {:bandit, "~> 1.5", only: [:dev, :test]}
    ]
  end
end
