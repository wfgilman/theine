defmodule Theine.Stress.BoundedTest do
  # Saturates every scheduler and samples on a timer, so it runs alone.
  use ExUnit.Case, async: false

  import Theine.Test.Helpers

  alias Theine.{Config, Maintenance}

  @moduletag :stress
  @moduletag timeout: 120_000

  @max_size 100_000
  @run_ms 10_000
  @sample_ms 10

  # Puts `key`, `key + step`, ... as fast as it can until `stop` is set, then
  # reports how many it put.
  defp write_until(cache, stop, key, step, test, count \\ 0) do
    if :atomics.get(stop, 1) == 0 do
      :ok = Theine.put(cache, key, key)
      write_until(cache, stop, key + step, step, test, count + 1)
    else
      send(test, {:writer_done, self(), count})
    end
  end

  test "entry count never exceeds max_size + write_hwm + schedulers under a 100% write workload" do
    cache = unique_cache()
    start_supervised!({Theine, name: cache, max_size: @max_size})
    config = Config.get(cache)
    writers = System.schedulers_online()
    bound = @max_size + config.write_hwm + writers
    stop = :atomics.new(1, [])
    test = self()

    # specs/09 §`mix bench maintenance`'s write run at a tenth of its size and
    # a third of its length: one writer per scheduler, distinct keys.
    pids =
      for s <- 1..writers do
        spawn_on_scheduler(s, fn -> write_until(cache, stop, s, writers, test) end)
      end

    deadline = System.monotonic_time(:millisecond) + @run_ms

    samples =
      Stream.repeatedly(fn ->
        size = :ets.info(cache, :size)
        Process.sleep(@sample_ms)
        size
      end)
      |> Enum.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)

    :atomics.put(stop, 1, 1)

    puts =
      for pid <- pids do
        assert_receive {:writer_done, ^pid, count}, 10_000
        count
      end
      |> Enum.sum()

    assert length(samples) >= div(@run_ms, @sample_ms * 2)
    assert Enum.max(samples) <= bound

    # The writers kept the cache at its bound and pushed it past max_size:
    # the samples measured the slack, not an idle table.
    assert puts > 2 * @max_size
    assert Enum.any?(samples, &(&1 > @max_size))

    # specs/09: one second after the writers stop the table is within
    # max_size, and the policy agrees with it. The second is the threshold
    # itself, not a wait for a background task.
    Process.sleep(1_000)
    assert :ets.info(cache, :size) <= @max_size
    assert %{pending: 0, size: size, weighted_size: size} = Maintenance.info(cache)
    assert size == :ets.info(cache, :size)
    assert Theine.stats(cache).evictions == puts - size
  end
end
