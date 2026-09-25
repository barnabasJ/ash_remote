defmodule AshCloner.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_cloner,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Monorepo dev convenience: reuse the parent repo's already-fetched deps
      # and lockfile so builds never need network access. Remove both before
      # publishing to hex (a standalone package must own its lockfile).
      deps_path: Path.expand("../../deps", __DIR__),
      lockfile: Path.expand("../../mix.lock", __DIR__),
      start_permanent: false,
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
      # Hard dep: the apply engine is built on `Ash.Resource.Igniter.*` and
      # `Ash.Resource.Validation.Builtins`.
      {:ash, "~> 3.29"},
      # `Spark.Igniter.find/3` is called directly by the engine.
      {:spark, "~> 2.6"},
      {:igniter, "~> 0.6"},
      {:sourceror, "~> 1.8"},
      # A SAT solver Ash needs at runtime (ash lists these as optional);
      # required to compile the fixture resources in the test suite.
      {:simple_sat, "~> 0.1"}
    ]
  end
end
