defmodule Theine.Stress.BackpressureTest do
  # Pins a writer to every scheduler and times a 10 s window, so it runs alone.
  use ExUnit.Case, async: false

  import Theine.Test.Helpers

  alias Theine.{Config, Maintenance}

  @moduletag :stress
  @moduletag timeout: 120_000

  @window_ms 10_000
  @sample_ms 10
  @puts_per_writer 20_000

  test "backpressure keeps the mailbox under write_hwm + schedulers through a 10 s paused window" do
    cache = unique_cache()

    # Unbounded, and the timer far out, so write events and their calls are
    # the only messages the paused process can receive (specs/03 §Acceptance
    # counts those).
    start_supervised!(
      {Theine, name: cache, max_size: :infinity, test_hooks: true, maintenance_interval: 60_000}
    )

    config = Config.get(cache)
    hwm = config.write_hwm
    maintenance = Process.whereis(Maintenance.name(cache))
    writers = System.schedulers_online()
    bound = hwm + writers
    returned = :counters.new(1, [:write_concurrency])
    test = self()

    :ok = Maintenance.pause(cache)

    for s <- 1..writers do
      spawn_on_scheduler(s, fn ->
        for i <- 1..@puts_per_writer do
          :ok = Theine.put(cache, {s, i}, i)
          :counters.add(returned, 1, 1)
        end

        send(test, {:writer_done, s})
      end)
    end

    # Every writer ends up blocked in a call: the first write_hwm events
    # were sent and their puts returned, and no further put can return
    # while the process is paused.
    deadline = System.monotonic_time(:millisecond) + @window_ms

    samples =
      Stream.repeatedly(fn ->
        {:message_queue_len, len} = Process.info(maintenance, :message_queue_len)
        sample = {len, :atomics.get(config.pending, 1), :counters.get(returned, 1)}
        Process.sleep(@sample_ms)
        sample
      end)
      |> Enum.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)

    assert length(samples) >= div(@window_ms, @sample_ms * 2)

    for {len, pending, done} <- samples do
      assert len <= bound
      assert pending <= bound
      assert done <= hwm
    end

    # At the end of the window nothing has moved since the writers blocked.
    assert {:message_queue_len, ^bound} = Process.info(maintenance, :message_queue_len)
    assert :atomics.get(config.pending, 1) == bound
    assert :counters.get(returned, 1) == hwm
    for s <- 1..writers, do: refute_received({:writer_done, ^s})

    # Reads never wait for the maintenance process.
    assert Theine.get(cache, {1, 1}) == {:ok, 1}

    # Resumed, every blocked writer's put returns and the rest of the run
    # goes through under the same bound.
    :ok = Maintenance.resume(cache)
    for s <- 1..writers, do: assert_receive({:writer_done, ^s}, 60_000)
    assert :counters.get(returned, 1) == writers * @puts_per_writer

    assert_eventually(fn -> Maintenance.info(cache).pending == 0 end, 10_000)
    assert Theine.size(cache) == writers * @puts_per_writer
    assert :ets.info(cache, :size) == writers * @puts_per_writer
  end
end
