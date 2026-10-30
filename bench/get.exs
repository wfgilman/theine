# mix bench get — read latency and throughput against raw ETS (specs/09, A1/A2),
# plus a put scenario against an ETS insert.
#
#   ERL_FLAGS="+sbt db +sbwt very_long" mix bench get
#   mix bench get --sizes 1000 --warmup 0.5 --time 1     # quick smoke run
#   mix bench get --scenarios get                        # skip the put runs
#
# Evaluates to the list of failed threshold descriptions (Mix.Tasks.Bench).

defmodule Theine.Bench.Get do
  import Cachex.Spec, only: [hook: 1]

  alias Theine.Bench.{NebulexCache, Report, Zipf}

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
  @rivals ["cachex", "nebulex"]
  # The put scenario's subjects (specs/09: theine vs ets insert vs Cachex vs
  # Nebulex). Its one threshold is on `theine`.
  @put_subjects ["ets", "theine", "cachex", "nebulex"]
  @scenarios ["get", "put"]

  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv,
        strict: [warmup: :float, time: :float, sizes: :string, scenarios: :string]
      )

    warmup = Keyword.get(opts, :warmup, 2.0)
    time = Keyword.get(opts, :time, 10.0)
    sizes = opts |> Keyword.get(:sizes) |> parse_csv(@sizes) |> Enum.map(&String.to_integer/1)
    scenarios = opts |> Keyword.get(:scenarios) |> parse_csv(@scenarios)
    parallels = Enum.uniq([1, System.schedulers_online()])
    full = System.schedulers_online()
    missing_flags = Report.check_erl_flags()

    unless scenarios != [] and Enum.all?(scenarios, &(&1 in @scenarios)) do
      raise ArgumentError, "--scenarios takes a subset of #{Enum.join(@scenarios, ",")}"
    end

    rows =
      for n <- sizes,
          value <- @values,
          row <- run_shape(n, value, scenarios, parallels, warmup, time),
          do: row

    rows = add_ratios(rows)
    thresholds = thresholds(rows, full)

    path =
      Report.write_json("get", %{
        system:
          Report.system(%{
            warmup_s: warmup,
            time_s: time,
            sizes: sizes,
            scenarios: scenarios,
            parallel: parallels,
            zipf_s: @zipf_s,
            missing_erl_flags: missing_flags
          }),
        results: rows,
        thresholds: thresholds
      })

    IO.puts(summary(rows, thresholds, path))

    thresholds |> Enum.reject(& &1.passed) |> Enum.map(& &1.description)
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
  defp run_shape(n, value, scenarios, parallels, warmup, time) do
    keys = Zipf.new(n, @zipf_s) |> Zipf.take(@key_samples, @seed + n) |> List.to_tuple()
    value_fun = value_fun(value)
    pairs = keys |> Tuple.to_list() |> Enum.map(&{&1, value_fun.(&1)}) |> List.to_tuple()
    shape = %{n: n, value: Atom.to_string(value)}

    for subject <- subjects(),
        rows =
          run_subject(subject, shape, value_fun, keys, pairs, scenarios, parallels, warmup, time),
        row <- List.flatten(rows),
        do: row
  end

  defp run_subject(subject, shape, value_fun, keys, pairs, scenarios, parallels, warmup, time) do
    runs =
      for scenario <- scenarios,
          scenario == "get" or subject.name in @put_subjects,
          parallel <- parallels,
          do: {scenario, parallel}

    if runs == [] do
      []
    else
      state = subject.setup.(shape.n, value_fun)

      try do
        for {scenario, parallel} <- runs do
          IO.puts(
            :stderr,
            "#{scenario}: n=#{shape.n} value=#{shape.value} #{subject.name} parallel=#{parallel}"
          )

          {job, samples} =
            case scenario do
              "get" -> {subject.get.(state), keys}
              "put" -> {subject.put.(state), pairs}
            end

          measure(scenario, subject.name, job, samples, shape, parallel, warmup, time)
        end
      after
        subject.teardown.(state)
      end
    end
  end

  # One job per suite. `samples` is a tuple of pre-drawn job inputs (keys,
  # or {key, value} pairs), one picked per call outside the measured time.
  defp measure(scenario, name, job, samples, shape, parallel, warmup, time) do
    count = tuple_size(samples)

    suite =
      Benchee.run(%{name => job},
        warmup: warmup,
        time: time,
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
  # put(state) -> ({key, value} -> _), teardown(state).
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
        teardown: &:ets.delete/1
      },
      # Bounded at exactly `n` (specs/09): the policy is on, every hit
      # records into the read buffer and the maintenance process drains
      # it concurrently with the readers.
      theine_subject("theine", :theine_bench_bounded, fn n -> [max_size: n] end),
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

  defp theine_subject(subject, name, opts) do
    %{
      name: subject,
      setup: fn n, value_fun ->
        {:ok, sup} = Theine.start_link([name: name] ++ opts.(n))
        populate(n, fn chunk -> Enum.each(chunk, &Theine.put(name, &1, value_fun.(&1))) end)
        wait_for_maintenance(name)
        {name, sup}
      end,
      get: fn {name, _sup} -> fn key -> Theine.get(name, key) end end,
      put: fn {name, _sup} -> fn {k, v} -> Theine.put(name, k, v) end end,
      teardown: fn {_name, sup} -> Supervisor.stop(sup) end
    }
  end

  defp populate(n, insert_chunk) do
    1..n |> Stream.chunk_every(10_000) |> Enum.each(insert_chunk)
  end

  # Every write event must be consumed before measuring, so the maintenance
  # process is idle and size/1 reflects the population.
  defp wait_for_maintenance(name) do
    :ok = Theine.run_maintenance(name)

    case Theine.Maintenance.info(name) do
      %{pending: 0} ->
        :ok

      %{pending: _} ->
        Process.sleep(10)
        wait_for_maintenance(name)
    end
  end

  defp add_ratios(rows) do
    floors =
      for %{subject: "ets"} = r <- rows,
          into: %{},
          do: {{r.scenario, r.n, r.value, r.parallel}, r}

    Enum.map(rows, fn r ->
      ets = Map.fetch!(floors, {r.scenario, r.n, r.value, r.parallel})

      Map.put(r, :ratio_to_ets, %{
        p50: r.p50_ns / ets.p50_ns,
        p99: r.p99_ns / ets.p99_ns,
        ips: r.ips / ets.ips
      })
    end)
  end

  defp thresholds(rows, full) do
    gets = Enum.filter(rows, &(&1.scenario == "get"))
    by_key = Map.new(gets, fn r -> {{r.subject, r.n, r.value, r.parallel}, r} end)

    get_checks =
      for r <- gets, r.subject in @theine_subjects, check <- checks(r, by_key, full) do
        check
      end

    # The put scenario's only threshold (specs/09), on every shape: a write
    # is an insert, an id allocation and a message send.
    put_checks =
      for %{scenario: "put", subject: "theine"} = r <- rows do
        shape = "n=#{r.n} #{r.value} parallel=#{r.parallel}"
        check("put", "theine put ips / ets insert ips, #{shape}", r.ratio_to_ets.ips, :>=, 0.5)
      end

    get_checks ++ put_checks
  end

  defp checks(r, by_key, full) do
    shape = "n=#{r.n} #{r.value} parallel=#{r.parallel}"

    a1 = [
      check("A1", "#{r.subject} p50 / ets p50, #{shape}", r.ratio_to_ets.p50, :<=, 1.5),
      check("A1", "#{r.subject} p99 / ets p99, #{shape}", r.ratio_to_ets.p99, :<=, 1.5)
    ]

    a2 =
      if r.parallel == full do
        vs_ets =
          check("A2", "#{r.subject} ips / ets ips, #{shape}", r.ratio_to_ets.ips, :>=, 0.65)

        vs_rivals =
          for rival <- @rivals, Map.has_key?(by_key, {rival, r.n, r.value, r.parallel}) do
            other = Map.fetch!(by_key, {rival, r.n, r.value, r.parallel})
            check("A2", "#{r.subject} ips / #{rival} ips, #{shape}", r.ips / other.ips, :>=, 2.0)
          end

        [vs_ets | vs_rivals]
      else
        []
      end

    a1 ++ a2
  end

  defp check(id, description, actual, op, limit) do
    passed = if op == :<=, do: actual <= limit, else: actual >= limit

    %{
      id: id,
      description: description,
      actual: actual,
      limit: "#{op} #{limit}",
      passed: passed
    }
  end

  defp summary(rows, thresholds, path) do
    header = [
      "scenario",
      "n",
      "value",
      "parallel",
      "subject",
      "p50 ns",
      "p99 ns",
      "ips",
      "p50/ets",
      "p99/ets",
      "ips/ets"
    ]

    table_rows =
      Enum.map(rows, fn r ->
        [
          r.scenario,
          r.n,
          r.value,
          r.parallel,
          r.subject,
          r.p50_ns,
          r.p99_ns,
          round(r.ips),
          r.ratio_to_ets.p50,
          r.ratio_to_ets.p99,
          r.ratio_to_ets.ips
        ]
      end)

    """
    ## mix bench get (#{Report.git_sha()})

    #{Report.table(header, table_rows)}

    #{Report.thresholds_markdown(thresholds, "none evaluated (no theine subject yet)")}

    Result: #{path}
    """
  end
end

Theine.Bench.Get.run(System.argv())
