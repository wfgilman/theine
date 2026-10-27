# mix bench get — read latency and throughput against raw ETS (specs/09, A1/A2).
#
#   ERL_FLAGS="+sbt db +sbwt very_long" mix bench get
#   mix bench get --sizes 1000 --warmup 0.5 --time 1     # quick smoke run
#
# Evaluates to the list of failed threshold descriptions (Mix.Tasks.Bench).

defmodule Theine.Bench.Get do
  alias Theine.Bench.{Report, Zipf}

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
  @theine_subjects ["theine", "theine_unbounded"]
  @rivals ["cachex", "nebulex"]

  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [warmup: :float, time: :float, sizes: :string])

    warmup = Keyword.get(opts, :warmup, 2.0)
    time = Keyword.get(opts, :time, 10.0)
    sizes = parse_sizes(Keyword.get(opts, :sizes))
    parallels = Enum.uniq([1, System.schedulers_online()])
    full = System.schedulers_online()
    missing_flags = Report.check_erl_flags()

    rows =
      for n <- sizes, value <- @values, row <- run_shape(n, value, parallels, warmup, time) do
        row
      end

    rows = add_ratios(rows)
    thresholds = thresholds(rows, full)

    path =
      Report.write_json("get", %{
        system:
          Report.system(%{
            warmup_s: warmup,
            time_s: time,
            sizes: sizes,
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

  defp parse_sizes(nil), do: @sizes

  defp parse_sizes(csv) do
    csv |> String.split(",", trim: true) |> Enum.map(&String.to_integer(String.trim(&1)))
  end

  # One shape: populate every subject once, then measure at each parallelism.
  defp run_shape(n, value, parallels, warmup, time) do
    keys = Zipf.new(n, @zipf_s) |> Zipf.take(@key_samples, @seed + n) |> List.to_tuple()
    value_fun = value_fun(value)
    subjects = Enum.map(subjects(), fn s -> Map.put(s, :state, s.setup.(n, value_fun)) end)

    try do
      for parallel <- parallels do
        IO.puts(:stderr, "get: n=#{n} value=#{value} parallel=#{parallel}")

        jobs = Map.new(subjects, fn s -> {s.name, s.get.(s.state)} end)

        suite =
          Benchee.run(jobs,
            warmup: warmup,
            time: time,
            parallel: parallel,
            memory_time: 0,
            reduction_time: 0,
            percentiles: [50, 99],
            before_each: fn _ -> elem(keys, :rand.uniform(@key_samples) - 1) end,
            formatters: [],
            print: [benchmarking: false, configuration: false, fast_warning: false]
          )

        Enum.map(suite.scenarios, fn scenario ->
          stats = scenario.run_time_data.statistics

          %{
            scenario: "get",
            subject: scenario.job_name,
            n: n,
            value: Atom.to_string(value),
            parallel: parallel,
            p50_ns: stats.percentiles[50],
            p99_ns: stats.percentiles[99],
            average_ns: stats.average,
            ips: stats.ips,
            sample_size: stats.sample_size
          }
        end)
      end
      |> List.flatten()
    after
      Enum.each(subjects, fn s -> s.teardown.(s.state) end)
    end
  end

  defp value_fun(:tuple3), do: fn k -> {k, :value, 42} end

  defp value_fun(:binary_1kb) do
    pool = List.to_tuple(for _ <- 1..@binary_pool, do: :rand.bytes(1_024))
    fn k -> elem(pool, rem(k, @binary_pool)) end
  end

  # Each subject: setup(n, value_fun) -> state, get(state) -> (key -> _),
  # teardown(state). Later milestones add the bounded theine subjects, cachex
  # and nebulex here.
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
        teardown: &:ets.delete/1
      },
      %{
        name: "theine_unbounded",
        setup: fn n, value_fun ->
          name = :theine_bench_unbounded
          {:ok, sup} = Theine.start_link(name: name, max_size: :infinity)
          populate(n, fn chunk -> Enum.each(chunk, &Theine.put(name, &1, value_fun.(&1))) end)
          wait_for_maintenance(name)
          {name, sup}
        end,
        get: fn {name, _sup} -> fn key -> Theine.get(name, key) end end,
        teardown: fn {_name, sup} -> Supervisor.stop(sup) end
      }
    ]
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
      for %{subject: "ets"} = r <- rows, into: %{}, do: {{r.n, r.value, r.parallel}, r}

    Enum.map(rows, fn r ->
      ets = Map.fetch!(floors, {r.n, r.value, r.parallel})

      Map.put(r, :ratio_to_ets, %{
        p50: r.p50_ns / ets.p50_ns,
        p99: r.p99_ns / ets.p99_ns,
        ips: r.ips / ets.ips
      })
    end)
  end

  defp thresholds(rows, full) do
    by_key = Map.new(rows, fn r -> {{r.subject, r.n, r.value, r.parallel}, r} end)

    for r <- rows, r.subject in @theine_subjects, check <- checks(r, by_key, full) do
      check
    end
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
