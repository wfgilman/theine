# mix bench get — read latency and throughput against raw ETS (specs/09, A1/A2),
# plus the put scenarios against an ETS insert: sustained puts (reported) and
# bursts of 1_000 puts (the threshold), and the partitioned hit (`theine_p4`)
# against the default cache's (specs/12).
#
#   ERL_FLAGS="+sbt db +sbwt very_long" mix bench get
#   mix bench get --sizes 1000 --warmup 0.5 --time 1 --bursts 100  # quick smoke run
#   mix bench get --scenarios get                        # skip the put runs
#   mix bench get --scenarios put_burst                  # only the put threshold
#   mix bench get --dev-floor                            # development machine
#
# Evaluates to the list of failed threshold descriptions (Mix.Tasks.Bench).
# With --dev-floor a check that misses its threshold inside the development
# band of specs/09 §Reference machine is a `floor`, not a failure
# (Theine.Bench.Verdict).

defmodule Theine.Bench.Get do
  import Cachex.Spec, only: [hook: 1]

  alias Theine.Bench.{NebulexCache, Report, Verdict, Zipf}

  @sizes [1_000, 100_000, 1_000_000]
  @values [:tuple3, :binary_1kb]
  @zipf_s 1.0
  @key_samples 65_536
  @seed 9
  # 1 KB values come from a pool so that 1M entries do not cost 1 GB, and so
  # that parallel readers do not all bump the refcount of one shared binary.
  @binary_pool 1_024

  # Theine subjects the A1/A2 thresholds apply to; `ets` is the floor and
  # `cachex`/`nebulex` the A2 comparison (specs/09 §mix bench get).
  # `theine_nostats` is reported for information only.
  @theine_subjects ["theine", "theine_unbounded"]
  # The partitioned cache (specs/12): `theine` with `partitions: 4`. A1/A2
  # stay on the default cache; its p50 is checked against `theine`'s on
  # every shape whose share is at least the minimum (specs/09 §Decisions
  # M8.5a). Measured right after `theine`, so the pair is close in time.
  @partitioned "theine_p4"
  @partitions 4
  # Each with its check kind: only `cachex` has a development band.
  @rivals [{"cachex", :ips_cachex}, {"nebulex", :ips_nebulex}]
  # The sustained put scenario's subjects (specs/09: theine vs ets insert vs
  # Cachex vs Nebulex), reported against `ets` and `cachex` with no threshold.
  @put_subjects ["ets", "theine", "cachex", "nebulex"]
  # The burst scenario's subjects: its threshold is `theine` against `ets`.
  @burst_subjects ["ets", "theine"]
  # Runs in this order within a subject, after its population. The bursts
  # come before the sustained puts so that they start from a drained cache,
  # not from the backlog of a 10 s write storm.
  @scenarios ["get", "put_burst", "put"]
  # Below the default `write_hwm` (1_024), so no write in a burst takes the
  # backpressure path (specs/03 §Delivery with backpressure).
  @burst 1_000
  @bursts 1_000

  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv,
        strict: [
          warmup: :float,
          time: :float,
          sizes: :string,
          scenarios: :string,
          bursts: :integer,
          dev_floor: :boolean
        ]
      )

    dev_floor = Keyword.get(opts, :dev_floor, false)
    warmup = Keyword.get(opts, :warmup, 2.0)
    time = Keyword.get(opts, :time, 10.0)
    bursts = Keyword.get(opts, :bursts, @bursts)
    sizes = opts |> Keyword.get(:sizes) |> parse_csv(@sizes) |> Enum.map(&String.to_integer/1)
    scenarios = opts |> Keyword.get(:scenarios) |> parse_csv(@scenarios)
    parallels = Enum.uniq([1, System.schedulers_online()])
    full = System.schedulers_online()
    missing_flags = Report.check_erl_flags()

    unless scenarios != [] and Enum.all?(scenarios, &(&1 in @scenarios)) do
      raise ArgumentError, "--scenarios takes a subset of #{Enum.join(@scenarios, ",")}"
    end

    unless bursts > 0, do: raise(ArgumentError, "--bursts takes a positive integer")

    # Run in @scenarios order whatever the order given. A tenth of the
    # bursts again run untimed first, as Benchee's warm-up.
    scenarios = Enum.filter(@scenarios, &(&1 in scenarios))
    timing = %{warmup: warmup, time: time, bursts: bursts, warmup_bursts: div(bursts, 10)}

    rows =
      for n <- sizes,
          value <- @values,
          row <- run_shape(n, value, scenarios, parallels, timing),
          do: row

    rows = add_ratios(rows)
    thresholds = thresholds(rows, full, dev_floor)

    path =
      Report.write_json("get", %{
        system:
          Report.system(%{
            dev_floor: dev_floor,
            warmup_s: warmup,
            time_s: time,
            burst_size: @burst,
            bursts: bursts,
            warmup_bursts: timing.warmup_bursts,
            sizes: sizes,
            scenarios: scenarios,
            parallel: parallels,
            zipf_s: @zipf_s,
            missing_erl_flags: missing_flags
          }),
        results: rows,
        thresholds: thresholds
      })

    IO.puts(summary(rows, thresholds, dev_floor, path))

    Verdict.failures(thresholds)
  end

  defp parse_csv(nil, default), do: Enum.map(default, &to_string/1)

  defp parse_csv(csv, _default) do
    csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  # One shape. Each subject is populated, measured and torn down before the
  # next is started, so no subject's background work (Cachex's janitor and
  # prune timer, Nebulex's generation rotation and the deletion of the old
  # generation 10 s later, theine's passes) runs while another is measured
  # (specs/09 §Decisions M5.1). Within a subject the get runs come first;
  # the puts rewrite keys already present with the value they hold, so the
  # subject stays at `n` entries.
  defp run_shape(n, value, scenarios, parallels, timing) do
    keys = Zipf.new(n, @zipf_s) |> Zipf.take(@key_samples, @seed + n) |> List.to_tuple()
    value_fun = value_fun(value)
    pairs = keys |> Tuple.to_list() |> Enum.map(&{&1, value_fun.(&1)}) |> List.to_tuple()
    shape = %{n: n, value: Atom.to_string(value)}
    inputs = %{keys: keys, pairs: pairs}

    for subject <- subjects(),
        rows = run_subject(subject, shape, value_fun, inputs, scenarios, parallels, timing),
        row <- List.flatten(rows),
        do: row
  end

  defp run_subject(subject, shape, value_fun, inputs, scenarios, parallels, timing) do
    runs =
      for scenario <- scenarios,
          runs_scenario?(scenario, subject.name),
          # The bursts measure one caller's cost (specs/09), so parallel 1 only.
          parallel <- if(scenario == "put_burst", do: [1], else: parallels),
          do: {scenario, parallel}

    available? = Map.get(subject, :available?, fn _n -> true end)

    cond do
      runs == [] ->
        []

      not available?.(shape.n) ->
        IO.puts(:stderr, "skipped: n=#{shape.n} #{subject.name} (#{subject.unavailable})")
        []

      true ->
        run_subject_scenarios(subject, shape, value_fun, inputs, runs, timing)
    end
  end

  defp run_subject_scenarios(subject, shape, value_fun, inputs, runs, timing) do
    state = subject.setup.(shape.n, value_fun)

    try do
      for {scenario, parallel} <- runs do
        IO.puts(
          :stderr,
          "#{scenario}: n=#{shape.n} value=#{shape.value} #{subject.name} parallel=#{parallel}"
        )

        case scenario do
          "get" ->
            measure(
              scenario,
              subject.name,
              subject.get.(state),
              inputs.keys,
              shape,
              parallel,
              timing
            )

          "put" ->
            measure(
              scenario,
              subject.name,
              subject.put.(state),
              inputs.pairs,
              shape,
              parallel,
              timing
            )

          "put_burst" ->
            measure_bursts(subject.name, subject.burst.(state), inputs.pairs, shape, timing)
        end
      end
    after
      subject.teardown.(state)
    end
  end

  defp runs_scenario?("get", _subject), do: true
  defp runs_scenario?("put", subject), do: subject in @put_subjects
  defp runs_scenario?("put_burst", subject), do: subject in @burst_subjects

  # The put threshold's measurement (specs/09 §mix bench get, burst): bursts
  # of @burst overwrites of present keys at parallel 1, each timed alone,
  # with the subject drained after each one outside the clock. For theine
  # the maintenance process runs throughout, consuming the burst's events
  # as they arrive; the drain waits until nothing is pending, so every
  # burst starts from the same state and stays below `write_hwm`. `burst`
  # is `{put_loop, drain}`: `put_loop.(pairs, from)` puts `@burst` pairs
  # starting at index `from` in a compiled loop, with no fun call per put.
  #
  # Row fields as the Benchee rows: `average_ns` is the total time over the
  # total puts (the threshold's figure), `p50_ns`/`p99_ns` are percentiles
  # of the per-burst average over the bursts, `ips` is 1 / `average_ns`,
  # and `sample_size` is the number of timed bursts.
  defp measure_bursts(name, {put_loop, drain}, pairs, shape, timing) do
    drain.()

    for b <- 1..timing.warmup_bursts//1 do
      put_loop.(pairs, b * @burst)
      drain.()
    end

    per_burst =
      for b <- 1..timing.bursts do
        from = (timing.warmup_bursts + b) * @burst
        t0 = :erlang.monotonic_time(:nanosecond)
        put_loop.(pairs, from)
        t1 = :erlang.monotonic_time(:nanosecond)
        drain.()
        t1 - t0
      end

    average = Enum.sum(per_burst) / (@burst * timing.bursts)
    sorted = per_burst |> Enum.sort() |> List.to_tuple()

    [
      Map.merge(shape, %{
        scenario: "put_burst",
        subject: name,
        parallel: 1,
        p50_ns: percentile(sorted, 50) / @burst,
        p99_ns: percentile(sorted, 99) / @burst,
        average_ns: average,
        ips: 1.0e9 / average,
        sample_size: timing.bursts
      })
    ]
  end

  # Nearest-rank percentile of a sorted, non-empty tuple.
  defp percentile(sorted, p) do
    count = tuple_size(sorted)
    elem(sorted, max(ceil(p * count / 100) - 1, 0))
  end

  defp ets_burst(_table, _pairs, _i, 0), do: :ok

  defp ets_burst(table, pairs, i, left) do
    :ets.insert(table, elem(pairs, Bitwise.band(i, @key_samples - 1)))
    ets_burst(table, pairs, i + 1, left - 1)
  end

  defp theine_burst(_name, _pairs, _i, 0), do: :ok

  defp theine_burst(name, pairs, i, left) do
    {k, v} = elem(pairs, Bitwise.band(i, @key_samples - 1))
    :ok = Theine.put(name, k, v)
    theine_burst(name, pairs, i + 1, left - 1)
  end

  # One job per suite. `samples` is a tuple of pre-drawn job inputs (keys,
  # or {key, value} pairs), one picked per call outside the measured time.
  defp measure(scenario, name, job, samples, shape, parallel, timing) do
    count = tuple_size(samples)

    suite =
      Benchee.run(%{name => job},
        warmup: timing.warmup,
        time: timing.time,
        parallel: parallel,
        memory_time: 0,
        reduction_time: 0,
        percentiles: [50, 99],
        before_each: fn _ -> elem(samples, :rand.uniform(count) - 1) end,
        formatters: [],
        print: [benchmarking: false, configuration: false, fast_warning: false]
      )

    Enum.map(suite.scenarios, fn s ->
      stats = s.run_time_data.statistics

      Map.merge(shape, %{
        scenario: scenario,
        subject: s.job_name,
        parallel: parallel,
        p50_ns: stats.percentiles[50],
        p99_ns: stats.percentiles[99],
        average_ns: stats.average,
        ips: stats.ips,
        sample_size: stats.sample_size
      })
    end)
  end

  defp value_fun(:tuple3), do: fn k -> {k, :value, 42} end

  defp value_fun(:binary_1kb) do
    pool = List.to_tuple(for _ <- 1..@binary_pool, do: :rand.bytes(1_024))
    fn k -> elem(pool, rem(k, @binary_pool)) end
  end

  # Each subject: setup(n, value_fun) -> state, get(state) -> (key -> _),
  # put(state) -> ({key, value} -> _), teardown(state), and for the subjects
  # in @burst_subjects burst(state) -> {put_loop, drain} (measure_bursts/5).
  defp subjects do
    [
      %{
        name: "ets",
        setup: fn n, value_fun ->
          # theine's entries-table options, verbatim (specs/01).
          table =
            :ets.new(:theine_bench_ets, [
              :set,
              :public,
              :named_table,
              read_concurrency: true,
              write_concurrency: :auto,
              decentralized_counters: true
            ])

          populate(n, fn chunk -> :ets.insert(table, Enum.map(chunk, &{&1, value_fun.(&1)})) end)
          table
        end,
        get: fn table -> fn key -> :ets.lookup(table, key) end end,
        put: fn table -> fn pair -> :ets.insert(table, pair) end end,
        burst: fn table ->
          {fn pairs, from -> ets_burst(table, pairs, from, @burst) end, fn -> :ok end}
        end,
        teardown: &:ets.delete/1
      },
      # Bounded at exactly `n` (specs/09): the policy is on, every hit
      # records into the read buffer and the maintenance process drains
      # it concurrently with the readers.
      theine_subject("theine", :theine_bench_bounded, fn n -> [max_size: n] end),
      # `theine` split into @partitions partitions (specs/12), each bounded
      # at its share of `n`. It needs a share of at least the minimum
      # (specs/12 §Settled questions 1), so it skips n=1_000. The keys hash
      # unevenly over the partitions, so a partition whose share is
      # overfull after the population evicts its excess: 195 keys of 100_000
      # in M8.5a (the `resident` line on stderr), whose reads miss.
      theine_subject(
        @partitioned,
        :theine_bench_partitioned,
        fn n -> [max_size: n, partitions: @partitions] end,
        fn n -> div(n, @partitions) >= Theine.Config.min_share() end,
        "partitions: #{@partitions} needs max_size >= #{@partitions * Theine.Config.min_share()}"
      ),
      theine_subject("theine_unbounded", :theine_bench_unbounded, fn _n ->
        [max_size: :infinity]
      end),
      # Bounded with `stats: false` (specs/08 §Stats): reported for
      # information, no threshold. A bounded hit has no counter op to skip,
      # so this measures the option's cost on the miss path alone.
      theine_subject("theine_nostats", :theine_bench_nostats, fn n ->
        [max_size: n, stats: false]
      end),
      # Cachex 4's size bound is a hook; `Cachex.Limit.Scheduled` is its
      # least-recently-written policy with default options (prune every 3 s
      # once the size is over `n`), the one its docs lead with.
      %{
        name: "cachex",
        setup: fn n, value_fun ->
          {:ok, sup} =
            Cachex.start_link(:theine_bench_cachex,
              hooks: [hook(module: Cachex.Limit.Scheduled, args: {n, [], []})]
            )

          populate(n, fn chunk ->
            {:ok, true} =
              Cachex.put_many(:theine_bench_cachex, Enum.map(chunk, &{&1, value_fun.(&1)}))
          end)

          sup
        end,
        get: fn _sup -> fn key -> Cachex.get(:theine_bench_cachex, key) end end,
        put: fn _sup -> fn {k, v} -> Cachex.put(:theine_bench_cachex, k, v) end end,
        teardown: &Supervisor.stop/1
      },
      # Nebulex 3's local adapter with `max_size: n` and its defaults
      # otherwise (stats and command telemetry on, a size check every 10 s).
      # It rotates generations once a check finds `size >= max_size`, so a
      # cache holding exactly `n` rotates during the run, and a hit on the
      # older generation moves the entry to the newer one (specs/09
      # §Decisions M5.1).
      %{
        name: "nebulex",
        setup: fn n, value_fun ->
          {:ok, sup} = NebulexCache.start_link(max_size: n)

          populate(n, fn chunk ->
            :ok = NebulexCache.put_all(Enum.map(chunk, &{&1, value_fun.(&1)}))
          end)

          sup
        end,
        get: fn _sup -> fn key -> NebulexCache.get(key) end end,
        put: fn _sup -> fn {k, v} -> NebulexCache.put(k, v) end end,
        teardown: fn _sup -> NebulexCache.stop() end
      }
    ]
  end

  defp theine_subject(subject, name, opts, available? \\ fn _n -> true end, unavailable \\ nil) do
    %{
      name: subject,
      available?: available?,
      unavailable: unavailable,
      setup: fn n, value_fun ->
        {:ok, sup} = Theine.start_link([name: name] ++ opts.(n))
        populate(n, fn chunk -> Enum.each(chunk, &Theine.put(name, &1, value_fun.(&1))) end)
        wait_for_maintenance(name)
        IO.puts(:stderr, "resident: n=#{n} #{subject} #{Theine.size(name)}")
        {name, sup}
      end,
      get: fn {name, _sup} -> fn key -> Theine.get(name, key) end end,
      put: fn {name, _sup} -> fn {k, v} -> Theine.put(name, k, v) end end,
      burst: fn {name, _sup} ->
        {fn pairs, from -> theine_burst(name, pairs, from, @burst) end,
         fn -> wait_for_maintenance(name) end}
      end,
      teardown: fn {_name, sup} -> Supervisor.stop(sup) end
    }
  end

  defp populate(n, insert_chunk) do
    1..n |> Stream.chunk_every(10_000) |> Enum.each(insert_chunk)
  end

  # Every write event must be consumed before measuring, so every
  # maintenance process is idle and size/1 reflects the population.
  defp wait_for_maintenance(name) do
    :ok = Theine.run_maintenance(name)
    partitions = Theine.Config.get(name).partitions

    if Enum.all?(0..(partitions - 1), &match?(%{pending: 0}, Theine.Maintenance.info(name, &1))) do
      :ok
    else
      Process.sleep(10)
      wait_for_maintenance(name)
    end
  end

  defp add_ratios(rows) do
    floors =
      for %{subject: "ets"} = r <- rows,
          into: %{},
          do: {{r.scenario, r.n, r.value, r.parallel}, r}

    cachex_puts =
      for %{scenario: "put", subject: "cachex"} = r <- rows,
          into: %{},
          do: {{r.n, r.value, r.parallel}, r}

    theine_gets =
      for %{scenario: "get", subject: "theine"} = r <- rows,
          into: %{},
          do: {{r.n, r.value, r.parallel}, r}

    Enum.map(rows, fn r ->
      ets = Map.fetch!(floors, {r.scenario, r.n, r.value, r.parallel})

      r
      |> Map.put(:ratio_to_ets, %{
        p50: r.p50_ns / ets.p50_ns,
        p99: r.p99_ns / ets.p99_ns,
        average: r.average_ns / ets.average_ns,
        ips: r.ips / ets.ips
      })
      |> put_cachex_ratio(Map.get(cachex_puts, {r.n, r.value, r.parallel}))
      |> put_theine_ratio(Map.get(theine_gets, {r.n, r.value, r.parallel}))
    end)
  end

  # The partitioned subject's get rows against `theine`'s (specs/12).
  defp put_theine_ratio(%{scenario: "get", subject: @partitioned} = r, %{} = theine) do
    Map.put(r, :ratio_to_theine, %{
      p50: r.p50_ns / theine.p50_ns,
      p99: r.p99_ns / theine.p99_ns,
      ips: r.ips / theine.ips
    })
  end

  defp put_theine_ratio(r, _theine), do: r

  # Sustained put rows are reported against `cachex` too (specs/09).
  defp put_cachex_ratio(%{scenario: "put"} = r, %{ips: ips}),
    do: Map.put(r, :ratio_to_cachex, %{ips: r.ips / ips})

  defp put_cachex_ratio(r, _cachex), do: r

  # The thresholds and the development band are Theine.Bench.Verdict's.
  defp thresholds(rows, full, dev_floor) do
    gets = Enum.filter(rows, &(&1.scenario == "get"))
    by_key = Map.new(gets, fn r -> {{r.subject, r.n, r.value, r.parallel}, r} end)

    get_checks =
      for r <- gets, r.subject in @theine_subjects, check <- checks(r, by_key, full, dev_floor) do
        check
      end

    # The put threshold (specs/09), on every shape: the caller's cost of a
    # put in a burst below `write_hwm` (an insert, an id allocation, a
    # `pending` increment and a message send) against an ETS insert.
    put_checks =
      for %{scenario: "put_burst", subject: "theine"} = r <- rows do
        Verdict.check(
          :put_burst,
          "theine burst cost per put / ets burst cost per insert, n=#{r.n} #{r.value}",
          r.ratio_to_ets.average,
          dev_floor
        )
      end

    # The partitioned hit (specs/12 §Settled questions 5): p50 at most 1.10
    # × `theine`'s, every shape and parallelism both subjects ran.
    partitioned_checks =
      for %{scenario: "get", subject: @partitioned, ratio_to_theine: ratio} = r <- rows do
        Verdict.check(
          :partitioned_p50,
          "#{@partitioned} p50 / theine p50, n=#{r.n} #{r.value} parallel=#{r.parallel}",
          ratio.p50,
          dev_floor
        )
      end

    get_checks ++ put_checks ++ partitioned_checks
  end

  defp checks(r, by_key, full, dev_floor) do
    shape = "n=#{r.n} #{r.value} parallel=#{r.parallel}"

    a1 =
      for p <- [:p50, :p99] do
        description = "#{r.subject} #{p} / ets #{p}, #{shape}"
        Verdict.check(:latency, description, Map.fetch!(r.ratio_to_ets, p), dev_floor)
      end

    a2 =
      if r.parallel == full do
        vs_ets =
          Verdict.check(
            :ips_ets,
            "#{r.subject} ips / ets ips, #{shape}",
            r.ratio_to_ets.ips,
            dev_floor
          )

        vs_rivals =
          for {rival, kind} <- @rivals, Map.has_key?(by_key, {rival, r.n, r.value, r.parallel}) do
            other = Map.fetch!(by_key, {rival, r.n, r.value, r.parallel})

            Verdict.check(
              kind,
              "#{r.subject} ips / #{rival} ips, #{shape}",
              r.ips / other.ips,
              dev_floor
            )
          end

        [vs_ets | vs_rivals]
      else
        []
      end

    a1 ++ a2
  end

  defp summary(rows, thresholds, dev_floor, path) do
    tables =
      [
        summary_table("get", rows, &get_table/1),
        partitioned_table(rows),
        summary_table("put_burst", rows, &burst_table/1),
        summary_table("put", rows, &put_table/1)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    """
    ## mix bench get (#{Report.git_sha()})

    #{machine()}

    #{tables}

    #{thresholds_markdown(thresholds, dev_floor)}

    Result: #{path}
    """
  end

  # The machine record specs/09 asks the final gate to keep with each run.
  defp machine do
    system = Report.system()

    "Machine: #{system.cpu_model}; #{system.os}; OTP #{system.otp}; " <>
      "schedulers_online #{system.schedulers_online}; ERL_FLAGS \"#{system.erl_flags}\""
  end

  # The strict count first, then (with --dev-floor) the verdict counts, then
  # every check that missed its threshold with its band and verdict.
  defp thresholds_markdown([], _dev_floor),
    do: "Thresholds: none evaluated (no theine subject yet)"

  defp thresholds_markdown(thresholds, dev_floor) do
    missed = Enum.reject(thresholds, & &1.passed)
    strict = "Thresholds: #{length(thresholds) - length(missed)}/#{length(thresholds)} passed"

    counts =
      if dev_floor do
        by_verdict = Enum.frequencies_by(thresholds, & &1.verdict)

        "\nDevelopment band (--dev-floor): " <>
          Enum.map_join(~w(pass floor fail), ", ", &"#{Map.get(by_verdict, &1, 0)} #{&1}")
      else
        ""
      end

    if missed == [] do
      strict <> counts
    else
      rows =
        Enum.map(missed, fn t -> [t.id, t.description, t.actual, t.limit, t.band, t.verdict] end)

      strict <>
        counts <>
        "\n\nMissed thresholds:\n\n" <>
        Report.table(~w(id check actual limit band verdict), rows)
    end
  end

  defp summary_table(scenario, rows, render) do
    case Enum.filter(rows, &(&1.scenario == scenario)) do
      [] -> nil
      scenario_rows -> render.(scenario_rows)
    end
  end

  defp get_table(rows) do
    header =
      ~w(scenario n value parallel subject) ++
        ["p50 ns", "p99 ns", "ips", "p50/ets", "p99/ets", "ips/ets"]

    Report.table(
      header,
      Enum.map(rows, fn r ->
        [r.scenario, r.n, r.value, r.parallel, r.subject, r.p50_ns, r.p99_ns, round(r.ips)] ++
          [r.ratio_to_ets.p50, r.ratio_to_ets.p99, r.ratio_to_ets.ips]
      end)
    )
  end

  # The partitioned subject's get rows beside `theine`'s; the threshold is
  # on `p50/theine`.
  defp partitioned_table(rows) do
    case for(%{ratio_to_theine: _} = r <- rows, do: r) do
      [] ->
        nil

      partitioned ->
        header =
          ~w(n value parallel) ++
            ["#{@partitioned} p50 ns", "p99 ns", "ips", "p50/theine", "p99/theine", "ips/theine"]

        Report.table(
          header,
          Enum.map(partitioned, fn r ->
            [r.n, r.value, r.parallel, r.p50_ns, r.p99_ns, round(r.ips)] ++
              [r.ratio_to_theine.p50, r.ratio_to_theine.p99, r.ratio_to_theine.ips]
          end)
        )
    end
  end

  # The threshold is on `ns/put` / ets; p50 and p99 are over the per-burst
  # averages.
  defp burst_table(rows) do
    header =
      ~w(scenario n value subject) ++
        ["ns/put", "burst p50 ns/put", "burst p99 ns/put", "bursts", "ns/put / ets"]

    Report.table(
      header,
      Enum.map(rows, fn r ->
        [r.scenario, r.n, r.value, r.subject, r.average_ns, r.p50_ns, r.p99_ns] ++
          [r.sample_size, r.ratio_to_ets.average]
      end)
    )
  end

  defp put_table(rows) do
    header =
      ~w(scenario n value parallel subject) ++
        ["p50 ns", "p99 ns", "ips", "ips/ets", "ips/cachex"]

    Report.table(
      header,
      Enum.map(rows, fn r ->
        cachex = if c = r[:ratio_to_cachex], do: c.ips

        [r.scenario, r.n, r.value, r.parallel, r.subject, r.p50_ns, r.p99_ns, round(r.ips)] ++
          [r.ratio_to_ets.ips, cachex]
      end)
    )
  end
end

Theine.Bench.Get.run(System.argv())
