# mix bench hitrate — hit rate of each policy on the replay traces (specs/09, A3).
#
#   mix bench hitrate
#   mix bench hitrate --traces loop,zipf         # a subset, by name
#   mix bench hitrate --window-percent 1,5,20    # sweep the window size (specs/05)
#   mix bench hitrate --memory-gb 2              # smaller replay passes
#   mix bench hitrate --accesses-per-pass 1      # synchronous, like Caffeine's simulator
#
# Replays every trace in bench/traces.exs at each of its sizes through every
# policy. Traces must already be in bench/traces/ with their recorded SHA-256
# (mix bench.traces); a missing one fails its rows instead of being skipped.
# Evaluates to the list of failed threshold descriptions (Mix.Tasks.Bench).

defmodule Theine.Bench.Hitrate do
  alias Theine.Bench.{Cache, LRU, Report, Traces}

  # A3: theine >= lru everywhere, and by this many points on these rows.
  @margin 10.0
  # OLTP carries no margin (specs/09 §Decisions 2026-10-29).
  @margin_rows [{"loop", 1_000}]

  # The `theine` row runs the default configuration: the adaptive window
  # starting at the specs/05 default of 1%. Other starting percentages of a
  # sweep are reported as `theine_w<p>` with no threshold. `theine_static`
  # is the fixed 1% window (`adaptive: false`), on every row, and `theine`
  # may trail it by at most this many points (specs/09, A3).
  @default_window_percent 1
  @static_slack 1.0

  # Instances replayed together may hold this much ETS (estimated from each
  # policy's bytes per entry). DS1's theine instances alone would need about
  # 5 GB; the reference laptop has 8.
  @default_memory_gb 4.0

  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv,
        strict: [
          traces: :string,
          manifest: :string,
          dir: :string,
          window_percent: :string,
          memory_gb: :float,
          accesses_per_pass: :integer
        ]
      )

    manifest = Traces.manifest(Keyword.get(opts, :manifest, Traces.default_manifest()))
    dir = Keyword.get(opts, :dir, Traces.default_dir())
    entries = select(manifest, opts[:traces])
    percents = window_percents(opts[:window_percent])
    budget = round(Keyword.get(opts, :memory_gb, @default_memory_gb) * 1_073_741_824)
    batch = accesses_per_pass(opts[:accesses_per_pass])
    policies = policies(percents, batch)

    rows = Enum.flat_map(entries, &run_trace(&1, dir, policies, budget))
    thresholds = availability(rows) ++ comparisons(rows)

    path =
      Report.write_json("hitrate", %{
        system:
          Report.system(%{
            traces: Enum.map(entries, & &1.name),
            policies: Enum.map(policies, & &1.name),
            window_percents: percents,
            accesses_per_pass: batch,
            memory_budget_bytes: budget
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

  defp window_percents(nil), do: [@default_window_percent]

  defp window_percents(csv) do
    percents =
      csv
      |> String.split(",", trim: true)
      |> Enum.map(fn s -> s |> String.trim() |> Integer.parse() end)

    case Enum.all?(percents, &match?({n, ""} when n in 1..80, &1)) do
      true -> percents |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      false -> Mix.raise("mix bench hitrate: --window-percent takes integers in 1..80")
    end
  end

  defp accesses_per_pass(nil), do: Cache.accesses_per_pass()

  defp accesses_per_pass(n) do
    if n in 1..Cache.max_accesses_per_pass(),
      do: n,
      else:
        Mix.raise(
          "mix bench hitrate: --accesses-per-pass takes 1..#{Cache.max_accesses_per_pass()}"
        )
  end

  # Each policy: new(trace, size) -> state, access(state, key) -> {:hit |
  # :miss, state}, close(state), and bytes_per_entry for the memory budget.
  defp policies(percents, batch) do
    lru = %{
      name: "lru",
      new: fn _trace, size -> LRU.new(size) end,
      access: &LRU.access/2,
      close: &LRU.close/1,
      bytes_per_entry: LRU.bytes_per_entry()
    }

    theine =
      for percent <- percents do
        %{
          name: theine_name(percent),
          new: fn trace, size ->
            Cache.new(trace, size, window_percent: percent, accesses_per_pass: batch)
          end,
          access: &Cache.access/2,
          close: &Cache.close/1,
          bytes_per_entry: Cache.bytes_per_entry()
        }
      end

    static = %{
      name: "theine_static",
      new: fn trace, size ->
        Cache.new(trace, size,
          window_percent: @default_window_percent,
          adaptive: false,
          accesses_per_pass: batch
        )
      end,
      access: &Cache.access/2,
      close: &Cache.close/1,
      bytes_per_entry: Cache.bytes_per_entry()
    }

    [lru | theine] ++ [static]
  end

  defp theine_name(@default_window_percent), do: "theine"
  defp theine_name(percent), do: "theine_w#{percent}"

  defp run_trace(entry, dir, policies, budget) do
    case Traces.verify(entry, dir) do
      :ok ->
        passes = passes(entry, policies, budget)

        passes
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {instances, index} ->
          replay(entry, dir, instances, {index, length(passes)})
        end)

      {:error, message} ->
        IO.puts(:stderr, "hitrate: " <> message)

        for size <- entry.sizes, policy <- policies do
          row(entry.name, size, policy.name, %{status: "error", error: message})
        end
    end
  end

  # The (size, policy) instances of a trace, packed in order into passes
  # over the file whose estimated ETS footprint stays within the budget. An
  # instance over the budget by itself gets a pass of its own.
  defp passes(entry, policies, budget) do
    instances = for policy <- policies, size <- entry.sizes, do: {size, policy}

    instances
    |> Enum.reduce([], fn {size, policy} = instance, passes ->
      cost = size * policy.bytes_per_entry

      case passes do
        [{current, used} | rest] when used + cost <= budget ->
          [{[instance | current], used + cost} | rest]

        _ ->
          [{[instance], cost} | passes]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {instances, _used} -> Enum.reverse(instances) end)
  end

  # One pass over the trace drives every instance of the pass at once.
  defp replay(entry, dir, instances, {index, count}) do
    names = Enum.map_join(instances, ", ", fn {size, policy} -> "#{policy.name} at #{size}" end)
    IO.puts(:stderr, "hitrate: #{entry.name} pass #{index}/#{count}: #{names}")

    instances =
      for {size, policy} <- instances do
        {size, policy, policy.new.(entry.name, size), 0}
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

  # Evaluated only for rows where both subjects ran.
  defp comparisons(rows) do
    by_key = Map.new(rows, fn r -> {{r.trace, r.size, r.policy}, r} end)

    against_lru =
      for %{policy: "theine", status: "ok"} = t <- rows,
          %{status: "ok"} = l <- [Map.get(by_key, {t.trace, t.size, "lru"})],
          margin <- margins(t) do
        delta = t.hit_rate - l.hit_rate
        check("A3", "theine - lru hit rate (points), #{t.trace} at #{t.size}", delta, :>=, margin)
      end

    against_static =
      for %{policy: "theine", status: "ok"} = t <- rows,
          %{status: "ok"} = s <- [Map.get(by_key, {t.trace, t.size, "theine_static"})] do
        delta = t.hit_rate - s.hit_rate

        check(
          "A3",
          "theine - theine_static hit rate (points), #{t.trace} at #{t.size}",
          delta,
          :>=,
          -@static_slack
        )
      end

    against_lru ++ against_static
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

    #{Report.thresholds_markdown(thresholds, "none evaluated (no theine row at window_percent #{@default_window_percent})")}

    Result: #{path}
    """
  end
end

Theine.Bench.Hitrate.run(System.argv())
