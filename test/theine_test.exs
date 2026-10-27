defmodule TheineTest do
  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.Config

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
