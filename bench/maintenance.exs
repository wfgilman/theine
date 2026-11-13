# mix bench maintenance — overshoot, pass duration and write backpressure under
# load (specs/09 §mix bench maintenance, A5; specs/04 §Budget).
#
#   mix bench maintenance
#   mix bench maintenance --max-size 40000 --duration 1    # quick smoke run
#
# Not Benchee: each subject runs the overshoot write run, then the mixed run,
# then the per-event write cost runs and the throughput runs at 1, 2 and 4
# partitions (reported only), then the overshoot write run again with
# `partitions: 4` (skipped below `--max-size 40000`, the minimum share),
# through Theine.Bench.Load. Evaluates to the list of failed threshold
# descriptions (Mix.Tasks.Bench).

defmodule Theine.Bench.Maintenance do
  alias Theine.Bench.{Load, Report}

  @max_size 1_000_000
  @duration_s 30.0
  @sample_ms 10
  @settle_ms 1_000
  # specs/08 defaults; every subject is started with them.
  @write_hwm 1_024
  @pass_budget_ms 5
  # The mixed run (specs/09; key space and seed per §Decisions M0.6).
  @read_fraction 0.75
  @ttl_ms 100
  @zipf_s 1.0
  @key_space_factor 2
  @seed 11
  # The per-event write cost (specs/09 §Decisions M7.1): a full cache of
  # this size, one writer for at most this long, each scenario run this
  # many times on a fresh cache. Reported, no threshold.
  @event_max_size 100_000
  @event_duration_s 5.0
  @event_runs 3
  @event_scenarios [:overwrite, :new]
  # Partitioned maintenance (specs/12, specs/09 §Decisions M8.5a): the
  # overshoot run again with `partitions: 4`, whose bound has one
  # `write_hwm` per partition, and the per-event scenarios at each of these
  # partition counts with one writer per scheduler (reported; the 2x gate
  # at 4 is the reference machine's, judged by a person).
  @overshoot_partitions 4
  @throughput_partitions [1, 2, 4]

  @none "no theine subject yet"

  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [max_size: :integer, duration: :float])

    max_size = Keyword.get(opts, :max_size, @max_size)
    duration_s = Keyword.get(opts, :duration, @duration_s)
    duration_ms = round(duration_s * 1000)
    # A smoke run's short --duration shortens the per-event runs too.
    event_ms = round(min(duration_s, @event_duration_s) * 1000)
    schedulers = System.schedulers_online()
    missing_flags = Report.check_erl_flags()

    rows =
      Enum.flat_map(subjects(), fn subject ->
        row =
          subject
          |> run_subject(max_size, duration_ms, schedulers)
          |> Map.put(:write_cost, write_cost(subject, event_ms))
          |> Map.put(:throughput, throughput(subject, event_ms, schedulers))

        [row | partitioned_rows(subject, max_size, duration_ms, schedulers)]
      end)

    thresholds = Enum.flat_map(rows, &thresholds(&1, schedulers))

    path =
      Report.write_json("maintenance", %{
        system:
          Report.system(%{
            max_size: max_size,
            duration_s: duration_ms / 1000,
            sample_ms: @sample_ms,
            settle_ms: @settle_ms,
            write_hwm: @write_hwm,
            pass_budget_ms: @pass_budget_ms,
            read_fraction: @read_fraction,
            ttl_ms: @ttl_ms,
            zipf_s: @zipf_s,
            key_space: @key_space_factor * max_size,
            event_max_size: @event_max_size,
            event_duration_s: event_ms / 1000,
            event_runs: @event_runs,
            overshoot_partitions: @overshoot_partitions,
            throughput_partitions: @throughput_partitions,
            subjects: Enum.map(subjects(), & &1.name),
            missing_erl_flags: missing_flags
          }),
        results: rows,
        thresholds: thresholds
      })

    IO.puts(summary(rows, thresholds, path))

    thresholds |> Enum.reject(& &1.passed) |> Enum.map(& &1.description)
  end

  # Each subject is a Theine.Bench.Load subject map. `theine` is a real
  # bounded cache started with the specs/08 defaults plus the run's
  # `max_size` and `write_hwm`; its state is the cache name. The size is
  # the entries table's own count (the table is named after the cache),
  # and the call-path write count is the maintenance process's
  # `call_writes` (specs/03 §Decisions M2.11).
  defp subjects do
    [
      %{
        name: "theine",
        start: fn opts ->
          name = :theine_bench_maintenance
          {:ok, _sup} = Theine.start_link([name: name] ++ opts)
          name
        end,
        put: fn name, key, value, ttl_ms ->
          case ttl_ms do
            nil -> Theine.put(name, key, value)
            ttl -> Theine.put(name, key, value, ttl: ttl)
          end
        end,
        get: fn name, key -> Theine.get(name, key) end,
        size: fn name -> :ets.info(name, :size) end,
        call_writes: fn name -> Theine.Maintenance.info(name).call_writes end,
        # A call queues behind every event already sent, and the pass it
        # runs leaves nothing pending.
        sync: fn name -> :ok = Theine.run_maintenance(name) end,
        stop: fn name -> Supervisor.stop(Theine.Supervisor.name(name)) end
      }
    ]
  end

  # A fresh cache for each run, so the mixed run does not start from the
  # write run's leftovers.
  defp run_subject(subject, max_size, duration_ms, schedulers) do
    start_opts = [max_size: max_size, write_hwm: @write_hwm]
    overshoot = overshoot(subject, subject.name, 1, max_size, duration_ms, schedulers)

    IO.puts(:stderr, "maintenance: #{subject.name} mixed run, #{duration_ms} ms")

    mixed =
      with_subject(subject, start_opts, fn state ->
        Load.mixed_run(subject, state,
          workers: schedulers,
          max_size: max_size,
          duration_ms: duration_ms,
          key_space: @key_space_factor * max_size,
          zipf_s: @zipf_s,
          read_fraction: @read_fraction,
          ttl_ms: @ttl_ms,
          seed: @seed
        )
      end)

    passes = mixed.pass_durations_us

    %{
      subject: subject.name,
      partitions: 1,
      max_size: max_size,
      overshoot: overshoot,
      pass: %{
        count: length(passes),
        p50_us: Load.percentile(passes, 50),
        p99_us: Load.percentile(passes, 99),
        max_us: Load.percentile(passes, 100)
      },
      backpressure: %{
        reads: mixed.reads,
        writes: mixed.writes,
        call_writes: mixed.call_writes,
        fraction: if(mixed.call_writes && mixed.writes > 0, do: mixed.call_writes / mixed.writes)
      }
    }
  end

  # The overshoot write run on a fresh cache of `partitions` partitions. The
  # bound has one `write_hwm` per partition (specs/12 §A5 with partitions);
  # at 1 it is the A5 bound of specs/09.
  defp overshoot(subject, label, partitions, max_size, duration_ms, schedulers) do
    start_opts = [max_size: max_size, write_hwm: @write_hwm, partitions: partitions]

    IO.puts(:stderr, "maintenance: #{label} write run, #{duration_ms} ms")

    write =
      with_subject(subject, start_opts, fn state ->
        Load.write_run(subject, state,
          writers: schedulers,
          duration_ms: duration_ms,
          sample_ms: @sample_ms,
          settle_ms: @settle_ms
        )
      end)

    %{
      limit: max_size + partitions * @write_hwm + schedulers,
      max_sample: write.max_sample,
      samples: length(write.samples),
      writes: write.writes,
      settled_size: write.settled_size
    }
  end

  # The overshoot run with `partitions: @overshoot_partitions` (specs/12
  # §Acceptance, Bound), a row with no mixed run and no per-event costs. A
  # `--max-size` below the minimum share of every partition cannot start
  # such a cache, so a smoke run that small skips it.
  defp partitioned_rows(subject, max_size, duration_ms, schedulers) do
    n = @overshoot_partitions
    label = "#{subject.name}_p#{n}"

    if div(max_size, n) < Theine.Config.min_share() do
      IO.puts(
        :stderr,
        "maintenance: #{label} skipped, partitions: #{n} needs --max-size >= " <>
          "#{n * Theine.Config.min_share()}"
      )

      []
    else
      [
        %{
          subject: label,
          partitions: n,
          max_size: max_size,
          overshoot: overshoot(subject, label, n, max_size, duration_ms, schedulers),
          pass: nil,
          backpressure: nil,
          write_cost: [],
          throughput: []
        }
      ]
    end
  end

  # The per-event scenarios with one writer per scheduler, at each of
  # @throughput_partitions (specs/12 §Acceptance, Throughput): mean puts/s
  # over @event_runs runs, and that against the run at one partition.
  defp throughput(subject, event_ms, schedulers) do
    rows =
      for partitions <- @throughput_partitions, scenario <- @event_scenarios do
        start_opts = [max_size: @event_max_size, write_hwm: @write_hwm, partitions: partitions]

        IO.puts(
          :stderr,
          "maintenance: #{subject.name} throughput partitions #{partitions} #{scenario}, " <>
            "#{schedulers} writers, #{@event_runs} x #{event_ms} ms"
        )

        runs =
          for i <- 1..@event_runs do
            with_subject(subject, start_opts, fn state ->
              Load.event_run(subject, state,
                fill: @event_max_size,
                keys: scenario,
                writers: schedulers,
                duration_ms: event_ms,
                seed: @seed + i
              )
            end)
          end

        %{
          partitions: partitions,
          scenario: Atom.to_string(scenario),
          writers: schedulers,
          max_size: @event_max_size,
          runs: runs,
          writes: runs |> Enum.map(& &1.writes) |> mean() |> round(),
          puts_per_s: mean(Enum.map(runs, & &1.puts_per_s)),
          us_per_event: mean(Enum.map(runs, & &1.us_per_event))
        }
      end

    base = for %{partitions: 1} = r <- rows, into: %{}, do: {r.scenario, r.puts_per_s}

    Enum.map(rows, fn r ->
      Map.put(r, :vs_one_partition, r.puts_per_s / Map.fetch!(base, r.scenario))
    end)
  end

  # One row per scenario: the mean puts/s and µs per event over
  # @event_runs runs, each on a fresh cache bounded at @event_max_size.
  defp write_cost(subject, event_ms) do
    start_opts = [max_size: @event_max_size, write_hwm: @write_hwm]

    for scenario <- @event_scenarios do
      IO.puts(
        :stderr,
        "maintenance: #{subject.name} per-event #{scenario} run, #{@event_runs} x #{event_ms} ms"
      )

      runs =
        for i <- 1..@event_runs do
          with_subject(subject, start_opts, fn state ->
            Load.event_run(subject, state,
              fill: @event_max_size,
              keys: scenario,
              duration_ms: event_ms,
              seed: @seed + i
            )
          end)
        end

      %{
        scenario: Atom.to_string(scenario),
        max_size: @event_max_size,
        runs: runs,
        writes: runs |> Enum.map(& &1.writes) |> mean() |> round(),
        puts_per_s: mean(Enum.map(runs, & &1.puts_per_s)),
        us_per_event: mean(Enum.map(runs, & &1.us_per_event))
      }
    end
  end

  defp mean(values) do
    if Enum.any?(values, &is_nil/1), do: nil, else: Enum.sum(values) / length(values)
  end

  defp with_subject(subject, start_opts, fun) do
    state = subject.start.(start_opts)

    try do
      fun.(state)
    after
      subject.stop.(state)
    end
  end

  defp thresholds(row, schedulers) do
    o = row.overshoot
    p = row.pass
    budget_us = @pass_budget_ms * 1000
    on = "#{row.subject}, max_size #{row.max_size}"

    hwm = if row.partitions == 1, do: "write_hwm", else: "#{row.partitions} * write_hwm"

    overshoot = [
      check(
        "A5",
        "max sampled size <= max_size + #{hwm} + schedulers (#{schedulers}), #{on}",
        o.max_sample,
        :<=,
        o.limit
      ),
      check(
        "A5",
        "size #{@settle_ms} ms after writers stop, #{on}",
        o.settled_size,
        :<=,
        row.max_size
      )
    ]

    # No pass events means the run measured nothing: fail rather than pass.
    # A partitioned row has no mixed run (`pass` is nil).
    passes =
      cond do
        p == nil ->
          []

        p.count == 0 ->
          [check("budget", "maintenance pass events observed, #{on}", 0, :>=, 1)]

        true ->
          [
            check("budget", "pass p99 (us), #{on}", p.p99_us, :<=, budget_us),
            check("budget", "pass max (us), #{on}", p.max_us, :<=, 4 * budget_us)
          ]
      end

    overshoot ++ passes
  end

  defp check(id, description, actual, op, limit) do
    passed =
      case op do
        :<= -> actual <= limit
        :>= -> actual >= limit
      end

    %{id: id, description: description, actual: actual, limit: "#{op} #{limit}", passed: passed}
  end

  defp summary(rows, thresholds, path) do
    """
    ## mix bench maintenance (#{Report.git_sha()})

    ### Overshoot (A5)

    #{section(rows, ["subject", "partitions", "max_size", "limit", "max sample", "samples", "writes", "settled size"], fn r -> [r.subject, r.partitions, r.max_size, r.overshoot.limit, r.overshoot.max_sample, r.overshoot.samples, r.overshoot.writes, r.overshoot.settled_size] end)}

    ### Pass duration (specs/04 budget, #{@pass_budget_ms} ms)

    #{section(mixed(rows), ["subject", "passes", "p50 us", "p99 us", "max us"], fn r -> [r.subject, r.pass.count, r.pass.p50_us, r.pass.p99_us, r.pass.max_us] end)}

    ### Write backpressure (reported, no threshold)

    #{section(mixed(rows), ["subject", "reads", "writes", "call-path writes", "fraction"], fn r -> [r.subject, r.backpressure.reads, r.backpressure.writes, r.backpressure.call_writes, r.backpressure.fraction] end)}

    ### Per-event write cost (reported, no threshold; one writer, mean of #{@event_runs} runs)

    #{write_cost_section(mixed(rows))}

    ### Throughput by partitions (reported, no threshold; one writer per scheduler, mean of #{@event_runs} runs)

    #{throughput_section(mixed(rows))}

    #{Report.thresholds_markdown(thresholds, "none evaluated (#{@none})")}

    Result: #{path}
    """
  end

  defp write_cost_section([]), do: @none

  defp write_cost_section(rows) do
    Report.table(
      ["subject", "scenario", "max_size", "writes", "puts/s", "us per event"],
      for r <- rows, c <- r.write_cost do
        [r.subject, c.scenario, c.max_size, c.writes, c.puts_per_s, c.us_per_event]
      end
    )
  end

  defp throughput_section([]), do: @none

  defp throughput_section(rows) do
    Report.table(
      ["subject", "partitions", "scenario", "writers", "max_size", "writes", "puts/s"] ++
        ["us per put", "x partitions 1"],
      for r <- rows, t <- r.throughput do
        [r.subject, t.partitions, t.scenario, t.writers, t.max_size, t.writes, t.puts_per_s] ++
          [t.us_per_event, t.vs_one_partition]
      end
    )
  end

  # The rows with a mixed run: the partitioned row has only the overshoot.
  defp mixed(rows), do: Enum.reject(rows, &is_nil(&1.pass))

  defp section([], _header, _cells), do: @none
  defp section(rows, header, cells), do: Report.table(header, Enum.map(rows, cells))
end

Theine.Bench.Maintenance.run(System.argv())
