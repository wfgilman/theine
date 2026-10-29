# mix bench maintenance — overshoot, pass duration and write backpressure under
# load (specs/09 §mix bench maintenance, A5; specs/04 §Budget).
#
#   mix bench maintenance
#   mix bench maintenance --max-size 10000 --duration 1    # quick smoke run
#
# Not Benchee: each subject runs the overshoot write run, then the mixed run,
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

  @none "no theine subject yet"

  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [max_size: :integer, duration: :float])

    max_size = Keyword.get(opts, :max_size, @max_size)
    duration_ms = round(Keyword.get(opts, :duration, @duration_s) * 1000)
    schedulers = System.schedulers_online()
    missing_flags = Report.check_erl_flags()

    rows = Enum.map(subjects(), &run_subject(&1, max_size, duration_ms, schedulers))
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
        stop: fn name -> Supervisor.stop(Theine.Supervisor.name(name)) end
      }
    ]
  end

  # A fresh cache for each run, so the mixed run does not start from the
  # write run's leftovers.
  defp run_subject(subject, max_size, duration_ms, schedulers) do
    start_opts = [max_size: max_size, write_hwm: @write_hwm]

    IO.puts(:stderr, "maintenance: #{subject.name} write run, #{duration_ms} ms")

    write =
      with_subject(subject, start_opts, fn state ->
        Load.write_run(subject, state,
          writers: schedulers,
          duration_ms: duration_ms,
          sample_ms: @sample_ms,
          settle_ms: @settle_ms
        )
      end)

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
      max_size: max_size,
      overshoot: %{
        limit: max_size + @write_hwm + schedulers,
        max_sample: write.max_sample,
        samples: length(write.samples),
        writes: write.writes,
        settled_size: write.settled_size
      },
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

    overshoot = [
      check(
        "A5",
        "max sampled size <= max_size + write_hwm + schedulers (#{schedulers}), #{on}",
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
    passes =
      if p.count == 0 do
        [check("budget", "maintenance pass events observed, #{on}", 0, :>=, 1)]
      else
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

    #{section(rows, ["subject", "max_size", "limit", "max sample", "samples", "writes", "settled size"], fn r -> [r.subject, r.max_size, r.overshoot.limit, r.overshoot.max_sample, r.overshoot.samples, r.overshoot.writes, r.overshoot.settled_size] end)}

    ### Pass duration (specs/04 budget, #{@pass_budget_ms} ms)

    #{section(rows, ["subject", "passes", "p50 us", "p99 us", "max us"], fn r -> [r.subject, r.pass.count, r.pass.p50_us, r.pass.p99_us, r.pass.max_us] end)}

    ### Write backpressure (reported, no threshold)

    #{section(rows, ["subject", "reads", "writes", "call-path writes", "fraction"], fn r -> [r.subject, r.backpressure.reads, r.backpressure.writes, r.backpressure.call_writes, r.backpressure.fraction] end)}

    #{Report.thresholds_markdown(thresholds, "none evaluated (#{@none})")}

    Result: #{path}
    """
  end

  defp section([], _header, _cells), do: @none
  defp section(rows, header, cells), do: Report.table(header, Enum.map(rows, cells))
end

Theine.Bench.Maintenance.run(System.argv())
