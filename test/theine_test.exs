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
