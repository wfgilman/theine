defmodule TheineTest do
  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.{Config, Entry}

  doctest Theine

  test "the application starts with an empty top-level supervisor" do
    assert {:ok, _} = Application.ensure_all_started(:theine)
    assert Supervisor.count_children(Theine.AppSupervisor).active == 0
  end

  describe "start_link/1" do
    test "starts two caches with different names" do
      a = unique_cache()
      b = unique_cache()
      start_supervised!({Theine, name: a, max_size: :infinity})
      start_supervised!({Theine, name: b, max_size: :infinity})

      for cache <- [a, b] do
        assert :ets.whereis(cache) != :undefined
        assert :ets.info(cache, :owner) == Process.whereis(Theine.Owner.name(cache))
        assert is_pid(Process.whereis(Theine.Supervisor.name(cache)))
        assert is_pid(Process.whereis(Theine.Maintenance.name(cache)))
        assert %Config{name: ^cache, table: ^cache} = config = Config.get(cache)
        assert is_pid(Process.whereis(config.task_supervisor))
      end

      refute Config.get(a).ids == Config.get(b).ids
    end

    test "second start of the same name returns already_started" do
      cache = unique_cache()
      sup = start_supervised!({Theine, name: cache, max_size: :infinity})

      assert Theine.start_link(name: cache, max_size: :infinity) ==
               {:error, {:already_started, sup}}
    end

    test "unknown option raises ArgumentError naming the option" do
      assert_raise ArgumentError, ~r/:bogus/, fn ->
        Theine.start_link(name: unique_cache(), max_size: :infinity, bogus: 1)
      end

      assert_raise ArgumentError, ~r/:bogus/, fn ->
        start_supervised!({Theine, name: unique_cache(), max_size: :infinity, bogus: 1})
      end
    end

    test "a cache cannot start when its name is a foreign persistent_term key" do
      cache = unique_cache()
      :persistent_term.put(cache, :not_a_cache)

      try do
        Process.flag(:trap_exit, true)

        assert {:error, {:shutdown, {:failed_to_start_child, Theine.Owner, {error, _}}}} =
                 Theine.start_link(name: cache, max_size: :infinity)

        assert %ArgumentError{message: message} = error
        assert message =~ inspect(cache)
        assert :persistent_term.get(cache) == :not_a_cache
      after
        :persistent_term.erase(cache)
      end
    end

    test "the entries table has the specs/01 options" do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: :infinity})

      assert :ets.info(cache, :type) == :set
      assert :ets.info(cache, :protection) == :public
      assert :ets.info(cache, :named_table)
      assert :ets.info(cache, :read_concurrency)
      assert :ets.info(cache, :write_concurrency) == :auto
      assert :ets.info(cache, :decentralized_counters)
    end

    test "the config in persistent_term carries the options and the runtime handles" do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: :infinity, write_hwm: 7})

      config = Config.get(cache)
      assert config.write_hwm == 7
      assert config.maintenance == Theine.Maintenance.name(cache)
      assert :atomics.add_get(config.ids, 1, 1) == 1
      assert :atomics.get(config.pending, 1) == 0
      assert :atomics.get(config.flags, Theine.Owner.drain_flag()) == 0
      assert :counters.info(config.counters).size == 7
      assert :atomics.info(config.sizes).size == 2
      assert config.read_buffer == nil
      assert config.sketch == nil
      # The hit path's one key: the request counters when unbounded.
      assert config.hit == config.counters
    end

    test "max_size: :infinity shows no sketch or read buffer in info/1" do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: :infinity})

      assert %{sketch: nil, read_buffer: nil, segments: nil} = Theine.Maintenance.info(cache)
      assert %Config{sketch: nil, read_buffer: nil} = Config.get(cache)
    end

    test "a finite max_size allocates the sketch and the read buffer once" do
      cache = unique_cache()

      start_supervised!({Theine, name: cache, max_size: 5_000, stripes: 4, read_buffer_slots: 16})

      config = Config.get(cache)
      assert %Theine.Sketch{words: 8192} = config.sketch
      assert :atomics.info(config.sketch.ref).size == 8192
      assert :atomics.info(config.read_buffer).size == 4 * (2 + 16)
      assert Theine.ReadBuffer.hits(config) == 0
      # The hit path's one key: the read-buffer tuple when bounded, with
      # the stripe mask, stripe width, slot mask and trigger mask (specs/03
      # §Decisions M2.8b).
      assert config.hit == {config.read_buffer, 3, 18, 15, config.drain_threshold - 1}

      assert %{
               sketch: %{words: 8192, increments: 0},
               read_buffer: %{stripes: 4, slots: 16, lag: 0},
               segments: %{window: 0, probation: 0, protected: 0}
             } = Theine.Maintenance.info(cache)

      # Writes and reads work as before; the policy places keys in the window.
      Theine.put(cache, :a, 1)
      assert Theine.get(cache, :a) == {:ok, 1}
      assert Theine.get(cache, :missing) == :error
      Theine.run_maintenance(cache)
      assert Theine.size(cache) == 1
      assert {:ok, {:a, _, :window, _, 1, :infinity}} = Theine.Maintenance.policy_row(cache, :a)

      # Killing Maintenance keeps the same sketch and buffer: the Owner
      # allocated them, and the config is written once.
      pid = Process.whereis(Theine.Maintenance.name(cache))
      Process.exit(pid, :kill)

      assert_eventually(fn ->
        Process.whereis(Theine.Maintenance.name(cache)) not in [nil, pid]
      end)

      assert Config.get(cache) == config
    end

    test "a bounded cache rejects an oversized entry at start_link level" do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: 10, weigher: fn _k, v -> v end})

      assert Theine.put(cache, :big, 11) == :ok
      assert Theine.put_new(cache, :big, 11) == :ok
      assert Theine.put(cache, :also_big, 1, weight: 11) == :ok
      assert Theine.get(cache, :big) == :error
      assert Theine.get(cache, :also_big) == :error
      assert :atomics.get(Config.get(cache).ids, 1) == 0

      assert Theine.put(cache, :fits, 10) == :ok
      assert Theine.get(cache, :fits) == {:ok, 10}
      Theine.run_maintenance(cache)
      assert %{pending: 0, size: 1, weighted_size: 10} = Theine.Maintenance.info(cache)
      assert Theine.Maintenance.policy_row(cache, :big) == :error
    end

    test "stopping the cache removes persistent_term, named tables and registered names" do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: :infinity})
      task_supervisor = Config.get(cache).task_supervisor

      :ok = stop_supervised!({Theine, cache})

      assert :persistent_term.get(Config.key(cache), :gone) == :gone
      assert :ets.whereis(cache) == :undefined

      for name <- [
            Theine.Supervisor.name(cache),
            Theine.Owner.name(cache),
            Theine.Maintenance.name(cache),
            task_supervisor
          ] do
        assert Process.whereis(name) == nil, "#{inspect(name)} is still registered"
      end
    end

    test "killing Owner restarts Owner, TaskSupervisor and Maintenance in order" do
      cache = unique_cache()
      sup = start_supervised!({Theine, name: cache, max_size: :infinity})
      :ets.insert(cache, {:k, :v, 1, 1, 0, :infinity})
      before = children(sup)
      config = Config.get(cache)

      # Spawn events from the supervisor, in the order it restarts children.
      session = :trace.session_create(__MODULE__, self(), [])
      1 = :trace.process(session, sup, true, [:procs])

      try do
        Process.exit(before[Theine.Owner], :kill)

        assert_eventually(fn ->
          after_restart = children(sup)

          Enum.all?(after_restart, fn {id, pid} ->
            is_pid(pid) and Process.alive?(pid) and pid != before[id]
          end)
        end)

        after_restart = children(sup)
        spawned = spawned_pids(sup)
        ids = for pid <- spawned, {id, ^pid} <- after_restart, do: id
        assert ids == [Theine.Owner, Theine.TaskSupervisor, Theine.Maintenance]
      after
        :trace.session_destroy(session)
      end

      # Usable and empty afterwards, with the config written only once.
      assert :ets.info(cache, :size) == 0
      assert :ets.info(cache, :owner) == children(sup)[Theine.Owner]
      assert Config.get(cache) == config
      assert :atomics.add_get(config.ids, 1, 1) == 1
      assert Theine.Maintenance.info(cache).passes == 0
    end
  end

  describe "put/4 and get/2" do
    setup do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: :infinity})
      %{cache: cache}
    end

    test "put then get from another process returns the value", %{cache: cache} do
      assert Theine.put(cache, :a, 1) == :ok

      task = Task.async(fn -> Theine.get(cache, :a) end)
      assert Task.await(task) == {:ok, 1}
    end

    test "get/2 on a missing key returns :error", %{cache: cache} do
      assert Theine.get(cache, :missing) == :error
    end

    test "get/3 returns the default on a miss", %{cache: cache} do
      Theine.put(cache, :a, 1)
      assert Theine.get(cache, :a, :default) == 1
      assert Theine.get(cache, :missing, :default) == :default
      assert Theine.get(cache, :missing, nil) == nil
    end

    test "put overwrites and assigns a fresh id per write", %{cache: cache} do
      Theine.put(cache, :a, 1)
      [{:a, 1, id1, 1, written1, :infinity}] = :ets.lookup(cache, :a)
      Theine.put(cache, :a, 2)
      [{:a, 2, id2, 1, written2, :infinity}] = :ets.lookup(cache, :a)

      assert Theine.get(cache, :a) == {:ok, 2}
      assert id1 >= 1 and id2 > id1
      assert written2 >= written1
    end

    test "put sets expires_at from ttl: or the cache default", %{cache: cache} do
      Theine.put(cache, :a, 1, ttl: 60_000)
      [{:a, 1, _, _, written, expires_at}] = :ets.lookup(cache, :a)
      assert expires_at == written + 60_000

      Theine.put(cache, :b, 1, ttl: :infinity)
      assert [{:b, 1, _, _, _, :infinity}] = :ets.lookup(cache, :b)

      default = unique_cache()
      start_supervised!({Theine, name: default, max_size: :infinity, expire_after_write: 500})
      Theine.put(default, :a, 1)
      [{:a, 1, _, _, written, expires_at}] = :ets.lookup(default, :a)
      assert expires_at == written + 500
      Theine.put(default, :b, 1, ttl: :infinity)
      assert [{:b, 1, _, _, _, :infinity}] = :ets.lookup(default, :b)
    end

    test "invalid ttl: or weight: raises ArgumentError naming the option", %{cache: cache} do
      assert_raise ArgumentError, ~r/:ttl/, fn -> Theine.put(cache, :a, 1, ttl: 0) end
      assert_raise ArgumentError, ~r/:ttl/, fn -> Theine.put(cache, :a, 1, ttl: :never) end
      assert_raise ArgumentError, ~r/:weight/, fn -> Theine.put(cache, :a, 1, weight: 0) end
      assert Theine.get(cache, :a) == :error
    end

    test "an entry past its expires_at is deleted by the reader and reported", %{cache: cache} do
      Theine.put(cache, :a, 1)
      Theine.run_maintenance(cache)
      assert Theine.size(cache) == 1
      [{:a, 1, id, 1, _, :infinity}] = :ets.lookup(cache, :a)

      past = System.monotonic_time(:millisecond) - 1
      true = :ets.update_element(cache, :a, {6, past})

      assert Theine.get(cache, :a) == :error
      assert :ets.lookup(cache, :a) == []

      # The reader sent {:removed, :a, id}; the calls below queue behind it.
      assert Theine.Maintenance.policy_row(cache, :a) == :error
      assert %{pending: 0, size: 0} = Theine.Maintenance.info(cache)
      assert id >= 1
    end

    test "size/1 counts distinct keys after overwrites once maintenance is idle", %{cache: cache} do
      for i <- 1..100, do: Theine.put(cache, rem(i, 10), i)
      Theine.run_maintenance(cache)

      assert Theine.size(cache) == 10
      assert Theine.weighted_size(cache) == 10
      assert Theine.Maintenance.info(cache).pending == 0
    end

    test "size/1 counts writes from many processes once pending is 0", %{cache: cache} do
      1..8
      |> Enum.map(fn w ->
        Task.async(fn -> for i <- 1..250, do: Theine.put(cache, {w, i}, i) end)
      end)
      |> Task.await_many()

      assert_eventually(fn -> Theine.Maintenance.info(cache).pending == 0 end)
      assert Theine.size(cache) == 2_000
    end

    test "weighted_size/1 follows weight: option", %{cache: cache} do
      Theine.put(cache, :a, 1, weight: 5)
      Theine.put(cache, :b, 1)
      Theine.run_maintenance(cache)
      assert Theine.size(cache) == 2
      assert Theine.weighted_size(cache) == 6

      Theine.put(cache, :a, 2, weight: 2)
      Theine.run_maintenance(cache)
      assert Theine.size(cache) == 2
      assert Theine.weighted_size(cache) == 3
    end
  end

  describe "get/2 under a bound" do
    test "reads of one key under a bound keep it resident while 10× distinct keys stream past" do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: 100, maintenance_interval: 60_000})
      Theine.put(cache, :hot, :v)
      Theine.run_maintenance(cache)

      # Every iteration writes a fresh key and reads :hot once; a pass every
      # 16 iterations applies the writes, drains the reads (so :hot moves
      # to its segment's MRU before eviction) and evicts the overflow.
      for i <- 1..1_000 do
        Theine.put(cache, {:cold, i}, i)
        assert {:ok, :v} = Theine.get(cache, :hot)
        if rem(i, 16) == 0, do: Theine.run_maintenance(cache)
      end

      Theine.run_maintenance(cache)
      assert_eventually(fn -> assert %{pending: 0} = Theine.Maintenance.info(cache) end)

      assert Theine.get(cache, :hot) == {:ok, :v}

      assert {:ok, {:hot, _, segment, _, 1, :infinity}} =
               Theine.Maintenance.policy_row(cache, :hot)

      assert segment in [:window, :probation, :protected]
      assert Theine.size(cache) <= 100
      assert %Theine.Stats{evictions: evictions, hits: 1_001} = Theine.stats(cache)
      assert evictions >= 900
    end

    # What `mix bench hitrate` relies on (specs/09 §Decisions M2.10): with the
    # reader's trigger out of reach and the interval timer far away, the
    # passes a replay runs with run_maintenance/1 are the only ones, so the
    # same key sequence through a cache of the same name (same :rand seed)
    # hits the same keys and keeps the same entries, run after run.
    test "a key sequence replayed twice through a cache of one name, driven by run_maintenance/1 alone, gives identical hits" do
      cache = unique_cache()

      # 20_000 accesses over 1_500 keys at max_size 500: a hot set drawn
      # from a seeded generator, interleaved with a scan.
      _ = :rand.seed(:exsss, {2026, 10, 29})

      keys =
        for i <- 1..20_000 do
          if rem(i, 3) == 0, do: {:scan, rem(i, 1_500)}, else: {:hot, :rand.uniform(300)}
        end

      replay = fn ->
        # drain_threshold 2^30: no reader's :drain within this replay; the
        # timer is far away; one stripe, so the pass applies a batch's reads
        # in access order wherever this process ran. The bench starts its
        # caches the same way.
        opts = [
          name: cache,
          max_size: 500,
          stripes: 1,
          drain_threshold: 1_073_741_824,
          maintenance_interval: 60_000
        ]

        start_supervised!({Theine, opts})

        {hits, runs} =
          keys
          |> Enum.with_index(1)
          |> Enum.reduce({0, 0}, fn {key, i}, {hits, runs} ->
            hits =
              case Theine.get(cache, key) do
                {:ok, _} ->
                  hits + 1

                :error ->
                  Theine.put(cache, key, i)
                  hits
              end

            if rem(i, 32) == 0 do
              Theine.run_maintenance(cache)
              {hits, runs + 1}
            else
              {hits, runs}
            end
          end)

        Theine.run_maintenance(cache)
        %{passes: passes, pending: pending} = Theine.Maintenance.info(cache)
        %Theine.Stats{hits: counted} = Theine.stats(cache)

        resident =
          cache |> :ets.select([{{:"$1", :_, :_, :_, :_, :_}, [], [:"$1"]}]) |> Enum.sort()

        :ok = stop_supervised!({Theine, cache})

        %{
          hits: hits,
          runs: runs + 1,
          passes: passes,
          pending: pending,
          counted: counted,
          resident: resident
        }
      end

      first = replay.()
      second = replay.()

      assert first == second
      assert %{hits: hits, runs: runs, passes: runs, pending: 0, counted: hits} = first
      assert hits > 2_000
      assert length(first.resident) <= 500
    end
  end

  describe "put_new/4, delete/2 and clear/1" do
    setup do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: :infinity})
      %{cache: cache}
    end

    test "put_new returns {:error, :exists} and sends no event", %{cache: cache} do
      assert Theine.put_new(cache, :a, 1, weight: 2) == :ok
      Theine.run_maintenance(cache)
      {:ok, {:a, id, nil, _, 2, :infinity}} = Theine.Maintenance.policy_row(cache, :a)

      assert Theine.put_new(cache, :a, 2, weight: 5) == {:error, :exists}

      assert Theine.get(cache, :a) == {:ok, 1}
      assert [{:a, 1, ^id, 2, _, :infinity}] = :ets.lookup(cache, :a)
      # No event: pending is untouched and the policy row is the original one.
      assert Theine.Maintenance.policy_row(cache, :a) == {:ok, {:a, id, nil, 1, 2, :infinity}}
      assert %{pending: 0, size: 1, weighted_size: 2} = Theine.Maintenance.info(cache)
    end

    test "put_new replaces an expired entry and counts the expiration" do
      cache = unique_cache()
      start_supervised!({Theine.Test.Clock, cache: cache, at: 1_000})
      start_supervised!({Theine, name: cache, max_size: :infinity})
      counters = Config.get(cache).counters

      assert Theine.put_new(cache, :a, 1, ttl: 10) == :ok
      [{:a, 1, old_id, 1, 1_000, 1_010}] = :ets.lookup(cache, :a)
      assert Theine.put_new(cache, :a, 2) == {:error, :exists}

      Theine.Test.Clock.advance(cache, 10)
      assert Theine.put_new(cache, :a, 2) == :ok

      assert [{:a, 2, new_id, 1, 1_010, :infinity}] = :ets.lookup(cache, :a)
      assert new_id > old_id
      assert Theine.get(cache, :a) == {:ok, 2}
      Theine.run_maintenance(cache)
      assert {:ok, {:a, ^new_id, nil, _, 1, :infinity}} = Theine.Maintenance.policy_row(cache, :a)
      assert %{pending: 0, size: 1} = Theine.Maintenance.info(cache)
      # One expiration, no miss (counter indices from specs/08 §Stats).
      assert :counters.get(counters, 6) == 1
      assert :counters.get(counters, 2) == 0
    end

    test "delete is idempotent and removes the policy row", %{cache: cache} do
      Theine.put(cache, :a, 1, weight: 3)
      Theine.put(cache, :b, 1)
      Theine.run_maintenance(cache)
      assert %{size: 2, weighted_size: 4} = Theine.Maintenance.info(cache)

      assert Theine.delete(cache, :a) == :ok
      assert Theine.get(cache, :a) == :error
      assert :ets.lookup(cache, :a) == []
      Theine.run_maintenance(cache)
      assert Theine.Maintenance.policy_row(cache, :a) == :error
      assert %{pending: 0, size: 1, weighted_size: 1} = Theine.Maintenance.info(cache)

      assert Theine.delete(cache, :a) == :ok
      assert Theine.delete(cache, :never_there) == :ok
      assert %{pending: 0, size: 1, weighted_size: 1} = Theine.Maintenance.info(cache)
      assert Theine.get(cache, :b) == {:ok, 1}
    end

    test "concurrent puts of one key followed by delete leave no policy row", %{cache: cache} do
      # Discovered issue 2 (specs/05 §Decisions M1.5): two writers racing on
      # one key can leave the policy row with an id the table never kept.
      # The delete's removal event must still clear the row.
      for round <- 1..200 do
        key = {:race, round}

        [
          Task.async(fn -> Theine.put(cache, key, :one) end),
          Task.async(fn -> Theine.put(cache, key, :two) end)
        ]
        |> Task.await_many()

        Theine.delete(cache, key)
      end

      Theine.run_maintenance(cache)
      assert %{pending: 0, size: 0, weighted_size: 0} = Theine.Maintenance.info(cache)
      assert :ets.info(cache, :size) == 0
    end

    test "clear empties the table and the policy tables before returning", %{cache: cache} do
      for i <- 1..100, do: Theine.put(cache, i, i, weight: 2)
      Theine.run_maintenance(cache)
      assert Theine.size(cache) == 100
      config = Config.get(cache)

      assert Theine.clear(cache) == :ok

      assert :ets.info(cache, :size) == 0
      assert Theine.size(cache) == 0
      assert Theine.weighted_size(cache) == 0
      assert Theine.get(cache, 1) == :error
      assert Theine.Maintenance.policy_row(cache, 1) == :error
      # Config untouched (specs/01 §Tables and handles), cache still usable.
      assert Config.get(cache) == config
      Theine.put(cache, :after, 1)
      Theine.run_maintenance(cache)
      assert Theine.get(cache, :after) == {:ok, 1}
      assert Theine.size(cache) == 1
    end

    test "oversized entry is not stored and produces no write event", %{cache: cache} do
      # The write path is exercised with a bounded copy of the running
      # cache's config; the start_link-level case is under start_link/1.
      config = %{Config.get(cache) | max_size: 10}

      assert Entry.put(config, :big, 1, weight: 11) == :ok
      assert Entry.put_new(config, :big, 1, weight: 11) == :ok
      assert :ets.lookup(cache, :big) == []
      assert :atomics.get(config.ids, 1) == 0
      assert %{pending: 0, size: 0} = Theine.Maintenance.info(cache)

      assert Entry.put(config, :fits, 1, weight: 10) == :ok
      assert Theine.get(cache, :fits) == {:ok, 1}
      Theine.run_maintenance(cache)
      assert %{pending: 0, size: 1, weighted_size: 10} = Theine.Maintenance.info(cache)
    end

    test "an oversized weigher result is rejected like weight:", %{cache: cache} do
      config = %{Config.get(cache) | max_size: 10, weigher: fn _k, v -> byte_size(v) end}

      assert Entry.put(config, :big, String.duplicate("x", 11), []) == :ok
      assert :ets.lookup(cache, :big) == []
      assert Entry.put(config, :small, "xxxxx", []) == :ok
      assert [{:small, "xxxxx", _, 5, _, :infinity}] = :ets.lookup(cache, :small)
    end

    test "weigher result is stored as the entry weight and weight: overrides it" do
      cache = unique_cache()

      start_supervised!(
        {Theine, name: cache, max_size: :infinity, weigher: fn _k, v -> byte_size(v) end}
      )

      Theine.put(cache, :a, "four")
      assert [{:a, "four", _, 4, _, :infinity}] = :ets.lookup(cache, :a)
      assert Theine.put_new(cache, :b, "sixsix") == :ok
      assert [{:b, "sixsix", _, 6, _, :infinity}] = :ets.lookup(cache, :b)
      Theine.put(cache, :c, "ignored", weight: 1)
      assert [{:c, "ignored", _, 1, _, :infinity}] = :ets.lookup(cache, :c)

      Theine.run_maintenance(cache)
      assert Theine.size(cache) == 3
      assert Theine.weighted_size(cache) == 11
    end

    test "a weigher that returns a bad weight raises ArgumentError" do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: :infinity, weigher: fn _k, v -> v end})

      assert_raise ArgumentError, ~r/weigher/, fn -> Theine.put(cache, :a, 0) end
      assert_raise ArgumentError, ~r/weigher/, fn -> Theine.put_new(cache, :a, :atom) end
      assert Theine.get(cache, :a) == :error
      assert Theine.put(cache, :a, 2) == :ok
    end
  end

  defp children(sup) do
    for {id, pid, _type, _modules} <- Supervisor.which_children(sup), into: %{}, do: {id, pid}
  end

  defp spawned_pids(sup) do
    receive do
      {:trace, ^sup, :spawn, pid, _mfa} -> [pid | spawned_pids(sup)]
    after
      0 -> []
    end
  end
end
