defmodule Theine.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/wfgilman/theine"

  def project do
    [
      app: :theine,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      name: "theine",
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
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
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
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

  defp description do
    "A bounded in-memory cache in pure Elixir, modelled on Caffeine: " <>
      "W-TinyLFU eviction, expire-after-write, single-flight loading and " <>
      "refresh-after-write over ETS and :atomics."
  end

  # The hex package (specs/00 A6, specs/10 §Gates step 7). `files:` is a
  # list, not Hex's default, because the default ships priv/ and so the
  # dialyzer PLTs in priv/plts. bench/ (with the dev-only `mix bench` task),
  # test/, specs/ and config/ stay out; package_test checks the list.
  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  # `mix docs` (specs/08 §Documentation). The bench modules compile in :dev
  # beside lib/ but are not part of the library, so they are filtered out.
  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md"],
      filter_modules: fn module, _metadata ->
        not String.starts_with?(inspect(module), ["Theine.Bench", "Mix.Tasks.Bench"])
      end,
      groups_for_modules: [
        API: [Theine, Theine.Stats],
        Internals: [
          Theine.Config,
          Theine.Entry,
          Theine.Sketch,
          Theine.ReadBuffer,
          Theine.WriteEvents,
          Theine.Maintenance,
          Theine.Policy,
          Theine.Expiry,
          Theine.Loader,
          Theine.Owner,
          Theine.Supervisor,
          Theine.Clock
        ]
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
