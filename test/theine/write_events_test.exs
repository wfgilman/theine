defmodule Theine.WriteEventsTest do
  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.{Config, Maintenance, WriteEvents}

  # One process per put, each reporting back when its put returns, so a test
  # can count how many writers got through and how many are blocked.
  defp spawn_writers(cache, n) do
    test = self()

    for i <- 1..n do
      spawn_link(fn ->
        :ok = Theine.put(cache, i, i)
        send(test, {:done, i})
      end)
    end
  end

  defp count_done(timeout, acc \\ 0) do
    receive do
      {:done, _} -> count_done(timeout, acc + 1)
    after
      timeout -> acc
    end
  end

  test "deliver/2 counts the event in pending and sends it to the maintenance name" do
    name = :"write_events_test_#{System.unique_integer([:positive])}"
    Process.register(self(), name)

    config = %{
      Config.new!(name: :write_events_test, max_size: :infinity)
      | pending: :atomics.new(1, signed: true),
        maintenance: name
    }

    assert WriteEvents.deliver(config, {:put, :a, 1, 1, :infinity}) == :ok
    assert WriteEvents.deliver(config, {:removed, :a, 1}) == :ok

    assert :atomics.get(config.pending, 1) == 2
    assert_received {:put, :a, 1, 1, :infinity}
    assert_received {:removed, :a, 1}
  end

  describe "deliver/2 never crashes the writer (specs/03 §Delivery with backpressure)" do
    # A config whose maintenance name nobody holds, as during a restart.
    defp unregistered_config(write_hwm) do
      name = :"write_events_absent_#{System.unique_integer([:positive])}"

      %{
        Config.new!(name: :write_events_test, max_size: :infinity, write_hwm: write_hwm)
        | pending: :atomics.new(1, signed: true),
          maintenance: name
      }
    end

    test "returns :ok on the send path when the maintenance name is not registered" do
      config = unregistered_config(1024)
      assert WriteEvents.deliver(config, {:put, :a, 1, 1, :infinity}) == :ok
      assert WriteEvents.deliver(config, {:removed, :a, 1}) == :ok
      assert :atomics.get(config.pending, 1) == 2
    end

    test "returns :ok on the call path when the maintenance name is not registered" do
      config = unregistered_config(1)
      :atomics.put(config.pending, 1, 1)
      assert WriteEvents.deliver(config, {:put, :a, 1, 1, :infinity}) == :ok
      assert :atomics.get(config.pending, 1) == 2
    end

    test "returns :ok when the maintenance process dies during the call" do
      config = unregistered_config(1)
      :atomics.put(config.pending, 1, 1)
      test = self()

      # Stands in for a maintenance process that crashes with the call in
      # its mailbox: it reports the call and exits without replying.
      server =
        spawn(fn ->
          Process.register(self(), config.maintenance)
          send(test, :registered)

          receive do
            {:"$gen_call", _from, {:event, event}} ->
              send(test, {:received, event})
              exit(:boom)
          end
        end)

      assert_receive :registered
      assert WriteEvents.deliver(config, {:put, :a, 1, 1, :infinity}) == :ok
      assert_received {:received, {:put, :a, 1, 1, :infinity}}
      refute Process.alive?(server)
    end
  end

  test "events from many writers all reach the maintenance process in put order per key" do
    cache = unique_cache()
    start_supervised!({Theine, name: cache, max_size: :infinity})

    1..4
    |> Enum.map(fn w ->
      Task.async(fn -> for i <- 1..500, do: Theine.put(cache, {w, rem(i, 50)}, i) end)
    end)
    |> Task.await_many()

    assert_eventually(fn -> Theine.Maintenance.info(cache).pending == 0 end)
    assert Theine.size(cache) == 200

    # The policy's id for each key is the id of the tuple in the table: each
    # writer sends its own key's events in order.
    for w <- 1..4, i <- 0..49 do
      [{_, _, id, _, _, _}] = :ets.lookup(cache, {w, i})
      assert {:ok, {_, ^id, _, _, _, _}} = Theine.Maintenance.policy_row(cache, {w, i})
    end
  end

  describe "backpressure (specs/03 §Delivery with backpressure)" do
    @hwm 8

    setup do
      cache = unique_cache()

      # The long interval keeps the timer out of the mailbox counts below.
      start_supervised!(
        {Theine,
         name: cache,
         max_size: :infinity,
         write_hwm: @hwm,
         test_hooks: true,
         maintenance_interval: 60_000}
      )

      %{
        cache: cache,
        config: Config.get(cache),
        maintenance: Process.whereis(Maintenance.name(cache))
      }
    end

    test "writers block once pending exceeds write_hwm while maintenance is paused", %{
      cache: cache,
      config: config
    } do
      :ok = Maintenance.pause(cache)
      spawn_writers(cache, @hwm + 3)

      # Every writer has counted its event: the first hwm sent and returned,
      # the rest are in a call that cannot be answered while paused.
      assert_eventually(fn -> :atomics.get(config.pending, 1) == @hwm + 3 end)
      assert count_done(50) == @hwm

      # The writes themselves all happened before any writer blocked.
      for i <- 1..(@hwm + 3), do: assert(Theine.get(cache, i) == {:ok, i})

      :ok = Maintenance.resume(cache)
      assert count_done(200) == 3
    end

    test "mailbox never exceeds write_hwm + schedulers messages", %{
      cache: cache,
      config: config,
      maintenance: maintenance
    } do
      writers = System.schedulers_online()
      puts_per_writer = 100
      test = self()

      :ok = Maintenance.pause(cache)

      for w <- 1..writers do
        spawn_link(fn ->
          for i <- 1..puts_per_writer, do: :ok = Theine.put(cache, {w, i}, i)
          send(test, {:writer_done, w})
        end)
      end

      # Wait until backpressure has engaged, then sample the mailbox for a
      # while: at most hwm plain events plus one call per blocked writer.
      assert_eventually(fn -> :atomics.get(config.pending, 1) > @hwm end)

      for _ <- 1..50 do
        {:message_queue_len, len} = Process.info(maintenance, :message_queue_len)
        assert len <= @hwm + writers
        assert :atomics.get(config.pending, 1) <= @hwm + writers
        Process.sleep(1)
      end

      :ok = Maintenance.resume(cache)
      for w <- 1..writers, do: assert_receive({:writer_done, ^w}, 5000)

      assert_eventually(fn -> Maintenance.info(cache).pending == 0 end)
      assert Theine.size(cache) == writers * puts_per_writer
    end

    test "every blocked writer returns :ok after resume and pending returns to 0", %{
      cache: cache,
      config: config
    } do
      blocked = 20
      :ok = Maintenance.pause(cache)
      spawn_writers(cache, @hwm + blocked)

      assert_eventually(fn -> :atomics.get(config.pending, 1) == @hwm + blocked end)
      assert count_done(50) == @hwm

      :ok = Maintenance.resume(cache)

      # Each blocked writer's `put` returned :ok (the spawned function
      # matches on it) and reported in.
      assert count_done(500) == blocked
      assert_eventually(fn -> Maintenance.info(cache).pending == 0 end)
      assert %{size: size} = Maintenance.info(cache)
      assert size == @hwm + blocked
    end
  end
end
