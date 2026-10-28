defmodule Theine.MaintenanceTest do
  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.{Config, Maintenance}

  setup do
    cache = unique_cache()
    start_supervised!({Theine, name: cache, max_size: :infinity})
    %{cache: cache}
  end

  test "info/1 reports the cache, pass count, last pass duration, pending and sizes", %{
    cache: cache
  } do
    assert Maintenance.info(cache) == %{
             cache: cache,
             passes: 0,
             last_pass_duration: nil,
             pending: 0,
             size: 0,
             weighted_size: 0
           }

    :atomics.add(Config.get(cache).pending, 1, 3)
    assert Maintenance.info(cache).pending == 3
  end

  test "run/1 returns :ok after one pass and info/1 counts it", %{cache: cache} do
    assert Maintenance.run(cache) == :ok
    assert Maintenance.run(cache) == :ok

    info = Maintenance.info(cache)
    assert info.passes == 2
    assert is_integer(info.last_pass_duration) and info.last_pass_duration >= 0
  end

  test "reset/1 returns :ok and forgets the pass history and the policy rows", %{cache: cache} do
    Theine.put(cache, :a, 1, weight: 2)
    :ok = Maintenance.run(cache)
    assert %{size: 1, weighted_size: 2} = Maintenance.info(cache)

    assert Maintenance.reset(cache) == :ok

    assert %{passes: 0, last_pass_duration: nil, size: 0, weighted_size: 0} =
             Maintenance.info(cache)

    assert Maintenance.policy_row(cache, :a) == :error
  end

  test "init resets pending and the drain flag", %{cache: cache} do
    config = Config.get(cache)
    :atomics.put(config.pending, 1, 9)
    :atomics.put(config.flags, Theine.Owner.drain_flag(), 1)
    pid = Process.whereis(Maintenance.name(cache))

    Process.exit(pid, :kill)
    assert_eventually(fn -> Process.whereis(Maintenance.name(cache)) not in [nil, pid] end)

    assert :atomics.get(config.pending, 1) == 0
    assert :atomics.get(config.flags, Theine.Owner.drain_flag()) == 0
    assert :ets.info(cache, :owner) == Process.whereis(Theine.Owner.name(cache))
  end

  describe "write events" do
    test "a :put event adds a policy row and decrements pending", %{cache: cache} do
      config = Config.get(cache)
      name = Maintenance.name(cache)

      :atomics.add(config.pending, 1, 1)
      send(name, {:put, :a, 7, 2, :infinity})

      assert Maintenance.policy_row(cache, :a) == {:ok, {:a, 7, nil, 1, 2, :infinity}}
      assert %{pending: 0, size: 1, weighted_size: 2} = Maintenance.info(cache)
    end

    test "a :removed event with the current id removes the row, a stale one is ignored", %{
      cache: cache
    } do
      config = Config.get(cache)
      name = Maintenance.name(cache)

      :atomics.add(config.pending, 1, 3)
      send(name, {:put, :a, 7, 1, :infinity})
      send(name, {:removed, :a, 6})
      assert Maintenance.policy_row(cache, :a) == {:ok, {:a, 7, nil, 1, 1, :infinity}}

      send(name, {:removed, :a, 7})
      assert Maintenance.policy_row(cache, :a) == :error
      assert %{pending: 0, size: 0, weighted_size: 0} = Maintenance.info(cache)
    end

    test "events are applied without a pass", %{cache: cache} do
      for i <- 1..50, do: Theine.put(cache, i, i)
      assert %{passes: 0, size: 50, weighted_size: 50, pending: 0} = Maintenance.info(cache)
    end

    test "an {:event, _} call is consumed in mailbox order and replied to", %{cache: cache} do
      config = Config.get(cache)
      name = Maintenance.name(cache)

      :atomics.add(config.pending, 1, 3)
      send(name, {:put, :a, 7, 1, :infinity})
      assert GenServer.call(name, {:event, {:put, :a, 8, 2, :infinity}}) == :ok
      assert GenServer.call(name, {:event, {:removed, :a, 7}}) == :ok

      # The stale removal arrived after the :put of id 8 and was ignored.
      assert Maintenance.policy_row(cache, :a) == {:ok, {:a, 8, nil, 1, 2, :infinity}}
      assert %{pending: 0, size: 1, weighted_size: 2} = Maintenance.info(cache)
    end
  end

  describe "pause/1 and resume/1" do
    test "raise ArgumentError without test_hooks", %{cache: cache} do
      assert_raise ArgumentError, ~r/test_hooks: true/, fn -> Maintenance.pause(cache) end
      assert_raise ArgumentError, ~r/test_hooks: true/, fn -> Maintenance.resume(cache) end
      assert Maintenance.info(cache).passes == 0
    end

    test "a paused process consumes nothing until resume, then everything" do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: :infinity, test_hooks: true})
      pid = Process.whereis(Maintenance.name(cache))

      assert Maintenance.pause(cache) == :ok
      for i <- 1..10, do: Theine.put(cache, i, i)
      Process.sleep(20)

      assert :atomics.get(Config.get(cache).pending, 1) == 10
      assert Process.info(pid, :message_queue_len) == {:message_queue_len, 10}
      assert Theine.size(cache) == 0

      assert Maintenance.resume(cache) == :ok
      assert %{pending: 0, size: 10} = Maintenance.info(cache)
    end

    test "resume/1 on a running process is a no-op" do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: :infinity, test_hooks: true})

      assert Maintenance.resume(cache) == :ok
      Theine.put(cache, :a, 1)
      assert %{pending: 0, size: 1} = Maintenance.info(cache)
    end
  end
end
