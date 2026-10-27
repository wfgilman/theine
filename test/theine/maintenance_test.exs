defmodule Theine.MaintenanceTest do
  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.{Config, Maintenance}

  setup do
    cache = unique_cache()
    start_supervised!({Theine, name: cache, max_size: :infinity})
    %{cache: cache}
  end

  test "info/1 reports the cache, pass count, last pass duration and pending events", %{
    cache: cache
  } do
    assert Maintenance.info(cache) == %{
             cache: cache,
             passes: 0,
             last_pass_duration: nil,
             pending: 0
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

  test "reset/1 returns :ok and forgets the pass history", %{cache: cache} do
    :ok = Maintenance.run(cache)
    assert Maintenance.reset(cache) == :ok
    assert %{passes: 0, last_pass_duration: nil} = Maintenance.info(cache)
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
end
