defmodule Theine.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :theine,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Theine.Application, []}
    ]
  end

  def cli do
    # `mix test` refuses to run inside an alias in :dev, so the whole gate
    # runs in :test (compile and dialyzer then also cover test/support).
    [preferred_envs: [gate: :test]]
  end

  # bench/lib holds `mix bench` and its helpers: compiled in :dev only, so
  # they never reach the hex package (specs/09; M5.4).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "bench/lib"]
  defp elixirc_paths(_), do: ["lib"]

  # Runtime: telemetry only (AGENTS.md). Everything else is dev/test/bench.
  defp deps do
    [
      {:telemetry, "~> 1.3"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      # The A2 rivals in `mix bench get` (specs/09). Not `runtime: false`:
      # the bench starts their caches in the dev VM.
      {:cachex, "~> 4.1", only: :dev},
      {:nebulex, "~> 3.1", only: :dev},
      {:nebulex_local, "~> 3.1", only: :dev}
    ]
  end

  # The gate reports coverage on every run: Theine.Loader and Theine.Policy
  # must show 100% lines in its table (specs/10 §Coverage).
  defp aliases do
    [
      gate: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test --cover",
        "dialyzer"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_core_path: "priv/plts",
      plt_local_path: "priv/plts",
      plt_add_apps: [:ex_unit, :stream_data],
      flags: [:error_handling, :extra_return, :missing_return, :underspecs]
    ]
  end
end
