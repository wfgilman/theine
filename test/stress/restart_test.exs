defmodule Theine.Stress.RestartTest do
  # Kills under load on every scheduler and times the recovery, so it runs alone.
  use ExUnit.Case, async: false

  import Theine.Test.Helpers

  alias Theine.{Config, Maintenance}

  @moduletag :stress
  @moduletag timeout: 120_000

  @max_size 100_000
  # New keys the writers insert between them, each evicting one entry once
  # the cache is full.
  @inserts 40_000

  def handle_rebuild(_event, measurements, %{cache: cache}, {test, cache}),
    do: send(test, {:rebuild, measurements})

  def handle_rebuild(_event, _measurements, _metadata, _config), do: :ok

  # Reads random prefilled keys until `stop` is set; an evicted key is a miss.
  defp read_until(cache, stop) do
    if :atomics.get(stop, 1) == 0 do
      _ = Theine.get(cache, :rand.uniform(@max_size))
      read_until(cache, stop)
    else
      :ok
    end
  end

  # Inserts `first`, `first + step`, ... `count` keys, each with itself as
  # the value, counting every put in `inserted`.
  defp insert(cache, first, step, count, inserted) do
    for k <- 0..(count - 1)//1 do
      key = first + k * step
      :ok = Theine.put(cache, key, key)
      :counters.add(inserted, 1, 1)
    end
  end

  test "killing Maintenance under load with 100_000 entries loses no readable entry and is back under max_size within two intervals" do
    cache = unique_cache()
    handler = {__MODULE__, cache}

    :ok =
      :telemetry.attach(
        handler,
        [:theine, :maintenance, :rebuild],
        &__MODULE__.handle_rebuild/4,
        {self(), cache}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    start_supervised!({Theine, name: cache, max_size: @max_size})
    config = Config.get(cache)
    interval = config.maintenance_interval
    assert_receive {:rebuild, %{entries: 0}}, 1_000

    for i <- 1..@max_size, do: :ok = Theine.put(cache, i, i)
    assert_eventually(fn -> Maintenance.info(cache).pending == 0 end, 10_000)
    assert :ets.info(cache, :size) == @max_size

    # Half the schedulers read, the other half insert new keys at full
    # speed, so at the kill the table sits past max_size by what the
    # writers' unconsumed events hold.
    schedulers = System.schedulers_online()
    readers = max(1, div(schedulers, 2))
    writers = max(1, schedulers - readers)
    per_writer = div(@inserts, writers)
    stop = :atomics.new(1, [])
    inserted = :counters.new(1, [:write_concurrency])
    test = self()

    reader_pids =
      for r <- 1..readers do
        spawn_on_scheduler(rem(r - 1, schedulers) + 1, fn -> read_until(cache, stop) end)
      end

    reader_refs = Enum.map(reader_pids, &Process.monitor/1)

    for w <- 1..writers do
      spawn_on_scheduler(rem(readers + w - 1, schedulers) + 1, fn ->
        insert(cache, @max_size + w, writers, per_writer, inserted)
        send(test, {:writer_done, w})
      end)
    end

    # A quarter of the way into the inserts: the entries readable now, and
    # the evictions so far. An entry of the snapshot may be evicted later;
    # it can only be missing at the end if an eviction after this point
    # removed it. The traversal runs under concurrent writes, so it may
    # miss or repeat an entry; the keys go into a set.
    assert_eventually(fn -> :counters.get(inserted, 1) >= div(@inserts, 4) end, 10_000)
    evicted_before = Theine.stats(cache).evictions
    snapshot = MapSet.new(:ets.tab2list(cache), &elem(&1, 0))
    assert MapSet.size(snapshot) > div(@max_size, 2)

    old = Process.whereis(Maintenance.name(cache))
    killed_at = System.monotonic_time(:millisecond)
    Process.exit(old, :kill)

    # The restarted process scans the table, and within two intervals of
    # the kill its policy is back within max_size, the writers still going.
    assert_receive {:rebuild, %{entries: restored}}, 2 * interval
    assert restored >= @max_size

    assert_eventually(
      fn ->
        pid = Process.whereis(Maintenance.name(cache))
        pid not in [nil, old] and Maintenance.info(cache).weighted_size <= @max_size
      end,
      2 * interval
    )

    assert System.monotonic_time(:millisecond) - killed_at <= 2 * interval

    for w <- 1..writers, do: assert_receive({:writer_done, ^w}, 30_000)
    :atomics.put(stop, 1, 1)
    for ref <- reader_refs, do: assert_receive({:DOWN, ^ref, :process, _, :normal}, 5_000)

    # Once idle no write event is lost: the policy holds exactly the table.
    assert_eventually(
      fn ->
        info = Maintenance.info(cache)
        assert info.size == :ets.info(cache, :size)
        assert info.weighted_size == info.size
      end,
      10_000
    )

    table = :ets.tab2list(cache)
    assert length(table) <= @max_size

    for {key, value, id, _weight, _written_at, _expires_at} <- table do
      assert value == key
      assert {:ok, {^key, ^id, _, _, 1, :infinity}} = Maintenance.policy_row(cache, key)
    end

    # No readable entry was lost: every snapshot entry the table no longer
    # holds is accounted for by an eviction since the snapshot. The kill can
    # land between an eviction's delete_object and its counter add
    # (Theine.Policy.evict/1), which loses at most that one count, here and
    # below.
    evicted = Theine.stats(cache).evictions
    present = MapSet.new(table, &elem(&1, 0))
    missing = MapSet.size(MapSet.difference(snapshot, present))
    assert missing <= evicted - evicted_before + 1

    # And overall: every key ever put (distinct, no deletes, no TTL) is in
    # the table or was evicted.
    puts = @max_size + :counters.get(inserted, 1)
    assert puts == @max_size + writers * per_writer
    assert (puts - (length(table) + evicted)) in 0..1
  end
end
