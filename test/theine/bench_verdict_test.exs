# bench/lib is compiled in :dev only (mix.exs), so the verdict module is
# loaded from its source here. It depends on nothing but Elixir.
Code.require_file("../../bench/lib/theine/bench/verdict.ex", __DIR__)

defmodule Theine.BenchVerdictTest do
  # `mix bench get` checks (specs/09 §`mix bench get`) and the development
  # band of `--dev-floor` (specs/09 §Reference machine). The band is not a
  # threshold: the pin below keeps Theine.Bench.Verdict and the spec's table
  # in step, so neither can move alone.
  use ExUnit.Case, async: true

  alias Theine.Bench.Verdict

  @root Path.expand("../..", __DIR__)

  # The spec table's first column, by check kind.
  @labels %{
    "A1 p50 and p99 / `ets`" => :latency,
    "A2 ips / `ets`" => :ips_ets,
    "A2 ips / `cachex`" => :ips_cachex,
    "A2 ips / `nebulex`" => :ips_nebulex,
    "put burst cost / `ets` insert" => :put_burst
  }

  defp spec_table do
    text = File.read!(Path.join(@root, "specs/09-benchmarks.md"))
    [_, rest] = String.split(text, "| check | threshold | development band |\n", parts: 2)
    [table | _] = String.split(rest, "\n\n", parts: 2)
    ["|---|---|---|" | rows] = String.split(table, "\n", trim: true)

    Map.new(rows, fn line ->
      [label, threshold, band] =
        line |> String.split("|", trim: true) |> Enum.map(&String.trim/1)

      {op, limit} = bound(threshold)

      band =
        case Regex.run(~r/^none \((.+)\)$/, band) do
          # "none (≥ 2)": no band, the threshold repeated.
          [_, same] ->
            assert bound(same) == {op, limit}, "#{label}: #{band} must repeat the threshold"
            nil

          nil ->
            {^op, band} = bound(band)
            band
        end

      {Map.fetch!(@labels, label), {op, limit, band}}
    end)
  end

  defp bound(cell) do
    [_, op, number] = Regex.run(~r/^(≤|≥) (\d+(?:\.\d+)?)$/, cell)
    {number, ""} = Float.parse(number)
    {%{"≤" => :<=, "≥" => :>=}[op], number}
  end

  test "the thresholds and the band are specs/09's table" do
    spec = spec_table()
    limits = Verdict.limits()

    assert Map.keys(spec) |> Enum.sort() == Map.keys(limits) |> Enum.sort()

    for {kind, {op, threshold, band}} <- spec do
      assert {^op, code_threshold, code_band} = Map.fetch!(limits, kind)
      assert code_threshold == threshold, "#{kind} threshold"
      assert code_band == band, "#{kind} band"
    end
  end

  defp verdict(kind, actual, dev_floor?),
    do: Verdict.check(kind, "check", actual, dev_floor?)

  describe "a check with a band" do
    # {kind, a pass, at the threshold, inside the band, at the band edge,
    # outside the band}
    @cases [
      {:latency, 1.2, 1.5, 1.6, 1.65, 1.7},
      {:ips_ets, 0.8, 0.65, 0.6, 0.52, 0.5},
      {:ips_cachex, 2.5, 2.0, 1.8, 1.7, 1.6}
    ]

    test "passes up to its threshold, inclusive, with or without the flag" do
      for {kind, pass, at, _, _, _} <- @cases, actual <- [pass, at], flag <- [true, false] do
        assert %{passed: true, verdict: "pass"} = verdict(kind, actual, flag), "#{kind} #{actual}"
      end
    end

    test "inside the band is a floor with the flag and a failure without it" do
      for {kind, _, _, inside, edge, _} <- @cases, actual <- [inside, edge] do
        assert %{passed: false, verdict: "floor"} = verdict(kind, actual, true)
        assert %{passed: false, verdict: "fail"} = verdict(kind, actual, false)
      end
    end

    test "outside the band fails with or without the flag" do
      for {kind, _, _, _, _, outside} <- @cases, flag <- [true, false] do
        assert %{passed: false, verdict: "fail"} = verdict(kind, outside, flag)
      end
    end

    test "records its id, limit and band" do
      assert %{id: "A1", kind: "latency", limit: "<= 1.5", band: "<= 1.65", actual: 1.6} =
               verdict(:latency, 1.6, false)

      assert %{id: "A2", limit: ">= 0.65", band: ">= 0.52"} = verdict(:ips_ets, 0.7, true)
      assert %{id: "A2", limit: ">= 2.0", band: ">= 1.7"} = verdict(:ips_cachex, 2.1, true)
    end
  end

  describe "a check with no band" do
    test "the nebulex ratio and the put burst fail on any miss, even with the flag" do
      for {kind, pass, miss} <- [{:ips_nebulex, 2.0, 1.99}, {:put_burst, 10, 10.01}] do
        for flag <- [true, false] do
          assert %{passed: true, verdict: "pass", band: nil} = verdict(kind, pass, flag)
          assert %{passed: false, verdict: "fail", band: nil} = verdict(kind, miss, flag)
        end
      end

      assert %{id: "put", limit: "<= 10"} = verdict(:put_burst, 6.0, true)
      assert %{id: "A2", limit: ">= 2.0"} = verdict(:ips_nebulex, 5.0, true)
    end
  end

  test "only a fail fails the run" do
    checks = [
      Verdict.check(:latency, "a pass", 1.0, true),
      Verdict.check(:latency, "a floor", 1.6, true),
      Verdict.check(:ips_ets, "a fail", 0.4, true),
      Verdict.check(:put_burst, "a put fail", 11, true)
    ]

    assert Verdict.failures(checks) == ["a fail", "a put fail"]

    strict =
      for c <- checks,
          do: Verdict.check(String.to_existing_atom(c.kind), c.description, c.actual, false)

    assert Verdict.failures(strict) == ["a floor", "a fail", "a put fail"]
  end
end
