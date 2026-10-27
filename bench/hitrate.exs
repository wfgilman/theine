# mix bench hitrate — hit rate of each policy on the replay traces (specs/09, A3).
#
#   mix bench hitrate
#   mix bench hitrate --traces loop,zipf     # a subset, by name
#
# Replays every trace in bench/traces.exs at each of its sizes through every
# policy, all in one pass over the trace. Traces must already be in
# bench/traces/ with their recorded SHA-256 (mix bench.traces); a missing one
# fails its rows instead of being skipped. Evaluates to the list of failed
# threshold descriptions (Mix.Tasks.Bench).

defmodule Theine.Bench.Hitrate do
  alias Theine.Bench.{LRU, Report, Traces}

  # A3: theine >= lru everywhere, and by this many points on these rows.
  @margin 10.0
  @margin_rows [{"loop", 1_000}, {"OLTP", 1_000}, {"OLTP", 2_000}]

  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [traces: :string, manifest: :string, dir: :string])

    manifest = Traces.manifest(Keyword.get(opts, :manifest, Traces.default_manifest()))
    dir = Keyword.get(opts, :dir, Traces.default_dir())
    entries = select(manifest, opts[:traces])

    rows = Enum.flat_map(entries, &run_trace(&1, dir))
    thresholds = availability(rows) ++ comparisons(rows)

    path =
      Report.write_json("hitrate", %{
        system:
          Report.system(%{
            traces: Enum.map(entries, & &1.name),
            policies: Enum.map(policies(), & &1.name)
          }),
        results: rows,
        thresholds: thresholds
      })

    IO.puts(summary(rows, thresholds, path))

    thresholds |> Enum.reject(& &1.passed) |> Enum.map(& &1.description)
  end

  defp select(manifest, nil), do: manifest

  defp select(manifest, csv) do
    wanted = csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    case wanted -- Enum.map(manifest, & &1.name) do
      [] -> Enum.filter(manifest, &(&1.name in wanted))
      unknown -> Mix.raise("mix bench hitrate: unknown trace(s) #{Enum.join(unknown, ", ")}")
    end
  end

  # Each policy: new(size) -> state, access(state, key) -> {:hit | :miss, state},
  # close(state). M2.10 adds `theine`, a real cache driven by run_maintenance/1.
  defp policies do
    [%{name: "lru", new: &LRU.new/1, access: &LRU.access/2, close: &LRU.close/1}]
  end

  defp run_trace(entry, dir) do
    case Traces.verify(entry, dir) do
      :ok ->
        replay(entry, dir)

      {:error, message} ->
        IO.puts(:stderr, "hitrate: " <> message)

        for size <- entry.sizes, policy <- policies() do
          row(entry.name, size, policy.name, %{status: "error", error: message})
        end
    end
  end

  # One pass over the trace drives every (size, policy) instance at once.
  defp replay(entry, dir) do
    IO.puts(:stderr, "hitrate: #{entry.name} at #{Enum.join(entry.sizes, ", ")}")

    instances =
      for size <- entry.sizes, policy <- policies() do
        {size, policy, policy.new.(size), 0}
      end

    {micros, {requests, instances}} =
      :timer.tc(fn ->
        Traces.reduce_keys(entry, dir, {0, instances}, fn key, {requests, instances} ->
          {requests + 1, Enum.map(instances, &access(&1, key))}
        end)
      end)

    for {size, policy, state, hits} <- instances do
      policy.close.(state)

      row(entry.name, size, policy.name, %{
        status: "ok",
        requests: requests,
        hits: hits,
        hit_rate: if(requests == 0, do: 0.0, else: 100 * hits / requests),
        seconds: micros / 1_000_000
      })
    end
  end

  defp access({size, policy, state, hits}, key) do
    case policy.access.(state, key) do
      {:hit, state} -> {size, policy, state, hits + 1}
      {:miss, state} -> {size, policy, state, hits}
    end
  end

  defp row(trace, size, policy, fields) do
    Map.merge(
      %{
        trace: trace,
        size: size,
        policy: policy,
        status: nil,
        error: nil,
        requests: nil,
        hits: nil,
        hit_rate: nil,
        seconds: nil
      },
      fields
    )
  end

  # A trace that could not be replayed fails A3 for its rows: specs/09 asks
  # for every trace, and the plan says missing ARC rows fail loudly.
  defp availability(rows) do
    for %{policy: "lru", status: "error"} = r <- rows do
      check("A3", "trace available, #{r.trace} at #{r.size}", 0, :==, 1)
    end
  end

  # Evaluated only for rows where both theine and lru ran.
  defp comparisons(rows) do
    by_key = Map.new(rows, fn r -> {{r.trace, r.size, r.policy}, r} end)

    for %{policy: "theine", status: "ok"} = t <- rows,
        %{status: "ok"} = l <- [Map.get(by_key, {t.trace, t.size, "lru"})],
        margin <- margins(t) do
      delta = t.hit_rate - l.hit_rate
      check("A3", "theine - lru hit rate (points), #{t.trace} at #{t.size}", delta, :>=, margin)
    end
  end

  defp margins(%{trace: trace, size: size}) do
    if {trace, size} in @margin_rows, do: [0.0, @margin], else: [0.0]
  end

  defp check(id, description, actual, op, limit) do
    passed =
      case op do
        :<= -> actual <= limit
        :>= -> actual >= limit
        :== -> actual == limit
      end

    %{id: id, description: description, actual: actual, limit: "#{op} #{limit}", passed: passed}
  end

  defp summary(rows, thresholds, path) do
    header = ["trace", "size", "policy", "requests", "hit rate %", "seconds", "status"]

    table_rows =
      Enum.map(rows, fn r ->
        [r.trace, r.size, r.policy, r.requests, r.hit_rate, r.seconds, r.error || r.status]
      end)

    """
    ## mix bench hitrate (#{Report.git_sha()})

    #{Report.table(header, table_rows)}

    #{Report.thresholds_markdown(thresholds, "none evaluated (no theine subject yet)")}

    Result: #{path}
    """
  end
end

Theine.Bench.Hitrate.run(System.argv())
