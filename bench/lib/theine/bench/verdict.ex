defmodule Theine.Bench.Verdict do
  @moduledoc """
  The checks of `mix bench get` and their verdicts (specs/09 §`mix bench
  get`, §Reference machine).

  Every check has a strict verdict, `passed`, against its threshold. With
  `--dev-floor` it also gets one of `"pass"`, `"floor"` (misses the
  threshold but stays inside the development band) or `"fail"`, and only a
  `"fail"` fails the run. Without the flag `verdict` is the strict one,
  `"pass"` or `"fail"`, so the exit status is the strict one.

  The thresholds and the band live here and nowhere else. bench_docs_test
  pins them to the table in specs/09 §Reference machine; the band is not a
  threshold and the loop may not widen it. This module has no dependency
  beyond Elixir, so the test can load it in `:test`, where `bench/lib` is
  not compiled.
  """

  # kind => {id, operator, threshold, development band or nil}. A check
  # with no band fails on any miss, with or without the flag.
  @checks %{
    latency: {"A1", :<=, 1.5, 1.65},
    ips_ets: {"A2", :>=, 0.65, 0.52},
    ips_cachex: {"A2", :>=, 2.0, 1.7},
    ips_nebulex: {"A2", :>=, 2.0, nil},
    put_burst: {"put", :<=, 10, nil}
  }

  @type kind :: :latency | :ips_ets | :ips_cachex | :ips_nebulex | :put_burst
  @type op :: :<= | :>=
  @type check :: %{
          id: String.t(),
          kind: String.t(),
          description: String.t(),
          actual: number(),
          limit: String.t(),
          band: String.t() | nil,
          passed: boolean(),
          verdict: String.t()
        }

  @doc "Every check kind with its operator, threshold and band (`nil`: none)."
  @spec limits() :: %{kind() => {op(), number(), number() | nil}}
  def limits do
    Map.new(@checks, fn {kind, {_id, op, threshold, band}} -> {kind, {op, threshold, band}} end)
  end

  @doc """
  Evaluates one check. `dev_floor?` is the `--dev-floor` flag: it changes
  `verdict` only, never `passed`.
  """
  @spec check(kind(), String.t(), number(), boolean()) :: check()
  def check(kind, description, actual, dev_floor?) do
    {id, op, threshold, band} = Map.fetch!(@checks, kind)
    passed = within?(actual, op, threshold)

    verdict =
      cond do
        passed -> "pass"
        dev_floor? and band != nil and within?(actual, op, band) -> "floor"
        true -> "fail"
      end

    %{
      id: id,
      kind: Atom.to_string(kind),
      description: description,
      actual: actual,
      limit: limit(op, threshold),
      band: if(band, do: limit(op, band)),
      passed: passed,
      verdict: verdict
    }
  end

  @doc "The descriptions of the checks that fail the run."
  @spec failures([check()]) :: [String.t()]
  def failures(checks), do: for(%{verdict: "fail"} = c <- checks, do: c.description)

  defp within?(actual, :<=, bound), do: actual <= bound
  defp within?(actual, :>=, bound), do: actual >= bound

  defp limit(op, bound), do: "#{op} #{bound}"
end
