defmodule Theine.StatsTest do
  @moduledoc """
  `Theine.stats/1` and `Theine.Stats` (specs/08 §Stats, §Acceptance;
  specs/03 §Hits from the tails).
  """

  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.{Config, Stats}
  alias Theine.Test.Clock

  doctest Theine.Stats

  describe "stats/1 on an unbounded cache" do
    setup do
      cache = unique_cache()
      start_supervised!({Clock, cache: cache, at: 1_000})
      start_supervised!({Theine, name: cache, max_size: :infinity})
      %{cache: cache}
    end

    test "hit_rate is 0.0 with no requests", %{cache: cache} do
      assert Theine.stats(cache) == %Stats{hit_rate: 0.0}
      assert Theine.stats(cache).hit_rate === 0.0
    end

    test "counts match a scripted sequence of hits, misses and expirations exactly",
         %{cache: cache} do
      Theine.put(cache, :a, 1)
      Theine.put(cache, :b, 2, ttl: 10)

      # 3 hits
      assert {:ok, 1} = Theine.get(cache, :a)
      assert 1 = Theine.get(cache, :a, nil)
      assert {:ok, 2} = Theine.get(cache, :b)

      # 2 misses
      assert :error = Theine.get(cache, :c)
      assert :default = Theine.get(cache, :d, :default)

      # 1 expired read: a miss and an expiration
      Clock.advance(cache, 10)
      assert :error = Theine.get(cache, :b)

      # put_new over an expired entry: an expiration, no miss (specs/01)
      Theine.put(cache, :e, 1, ttl: 5)
      Clock.advance(cache, 5)
      assert :ok = Theine.put_new(cache, :e, 2)

      assert Theine.stats(cache) == %Stats{
               hits: 3,
               misses: 3,
               loads: 0,
               load_failures: 0,
               evictions: 0,
               expirations: 2,
               refreshes: 0,
               hit_rate: 0.5
             }
    end

    test "hit_rate is hits over hits plus misses", %{cache: cache} do
      Theine.put(cache, :a, 1)
      for _ <- 1..3, do: {:ok, 1} = Theine.get(cache, :a)
      :error = Theine.get(cache, :missing)

      assert %Stats{hits: 3, misses: 1, hit_rate: 0.75} = Theine.stats(cache)
    end

    test "clear/1 leaves the statistics untouched", %{cache: cache} do
      Theine.put(cache, :a, 1)
      {:ok, 1} = Theine.get(cache, :a)
      :error = Theine.get(cache, :b)

      :ok = Theine.clear(cache)
      assert %Stats{hits: 1, misses: 1} = Theine.stats(cache)
    end

    test "counts from several processes add up", %{cache: cache} do
      Theine.put(cache, :a, 1)

      1..8
      |> Enum.map(fn i ->
        Task.async(fn ->
          for _ <- 1..100, do: {:ok, 1} = Theine.get(cache, :a)
          for _ <- 1..i, do: :error = Theine.get(cache, {:missing, i})
        end)
      end)
      |> Task.await_many()

      assert %Stats{hits: 800, misses: 36} = Theine.stats(cache)
    end
  end

  describe "stats: false" do
    setup do
      cache = unique_cache()
      start_supervised!({Clock, cache: cache, at: 1_000})
      start_supervised!({Theine, name: cache, max_size: :infinity, stats: false})
      %{cache: cache}
    end

    test "counts neither hits nor misses on get/2", %{cache: cache} do
      Theine.put(cache, :a, 1)
      assert {:ok, 1} = Theine.get(cache, :a)
      assert :error = Theine.get(cache, :b)
      assert 0 = Theine.get(cache, :b, 0)

      assert Theine.stats(cache) == %Stats{hit_rate: 0.0}
    end

    test "still counts expirations, an expired read included", %{cache: cache} do
      Theine.put(cache, :a, 1, ttl: 10)
      Theine.put(cache, :b, 1, ttl: 10)
      Clock.advance(cache, 10)

      assert :error = Theine.get(cache, :a)
      assert :ok = Theine.put_new(cache, :b, 2)

      assert %Stats{hits: 0, misses: 0, expirations: 2, hit_rate: +0.0} = Theine.stats(cache)
    end
  end

  describe "stats/1 on a bounded cache" do
    # One stripe of four slots: the buffer drops after four unread hits,
    # and the tails still count every hit (specs/03 §Hits from the tails).
    @bounded [
      max_size: 100,
      stripes: 1,
      read_buffer_slots: 4,
      maintenance_interval: 60_000,
      test_hooks: true
    ]

    setup do
      cache = unique_cache()
      start_supervised!({Clock, cache: cache, at: 1_000})
      start_supervised!({Theine, [name: cache] ++ @bounded})
      %{cache: cache}
    end

    test "counts match a scripted sequence of hits, misses and expirations exactly",
         %{cache: cache} do
      Theine.put(cache, :a, 1)
      Theine.put(cache, :b, 2, ttl: 10)

      assert {:ok, 1} = Theine.get(cache, :a)
      assert 1 = Theine.get(cache, :a, nil)
      assert {:ok, 2} = Theine.get(cache, :b)
      assert :error = Theine.get(cache, :c)
      assert :default = Theine.get(cache, :d, :default)

      Clock.advance(cache, 10)
      assert :error = Theine.get(cache, :b)

      Theine.put(cache, :e, 1, ttl: 5)
      Clock.advance(cache, 5)
      assert :ok = Theine.put_new(cache, :e, 2)

      assert %Stats{hits: 3, misses: 3, expirations: 2, evictions: 0, hit_rate: 0.5} =
               Theine.stats(cache)

      # The hits counter is never touched by a bounded hit (specs/08 §Stats).
      assert :counters.get(Config.get(cache).counters, Stats.hits()) == 0
    end

    test "bounded hits equal the number of successful gets even when the read buffer drops (maintenance paused)",
         %{cache: cache} do
      Theine.put(cache, :a, 1)
      Theine.run_maintenance(cache)
      Theine.Maintenance.pause(cache)

      for _ <- 1..100, do: {:ok, 1} = Theine.get(cache, :a)
      for _ <- 1..3, do: :error = Theine.get(cache, :missing)

      assert %Stats{hits: 100, misses: 3} = Theine.stats(cache)

      Theine.Maintenance.resume(cache)
      # At most `slots` reads survived in the ring; the count did not care.
      # The reader's queued :drain may be deferred by drain_backoff behind
      # the last pass, so drain with a pass that never is.
      Theine.run_maintenance(cache)
      assert %{read_buffer: %{lag: 0}} = Theine.Maintenance.info(cache)
      assert %Stats{hits: 100, misses: 3} = Theine.stats(cache)
    end

    test "a Maintenance restart does not reset bounded hits", %{cache: cache} do
      Theine.put(cache, :a, 1)
      for _ <- 1..5, do: {:ok, 1} = Theine.get(cache, :a)
      assert %Stats{hits: 5} = Theine.stats(cache)

      pid = Process.whereis(Theine.Maintenance.name(cache))
      Process.exit(pid, :kill)

      assert_eventually(fn ->
        Process.whereis(Theine.Maintenance.name(cache)) not in [nil, pid]
      end)

      assert %Stats{hits: 5} = Theine.stats(cache)
      for _ <- 1..2, do: {:ok, 1} = Theine.get(cache, :a)
      assert %Stats{hits: 7} = Theine.stats(cache)
    end

    test "counts from several processes add up", %{cache: cache} do
      Theine.put(cache, :a, 1)

      1..8
      |> Enum.map(fn i ->
        Task.async(fn ->
          for _ <- 1..100, do: {:ok, 1} = Theine.get(cache, :a)
          for _ <- 1..i, do: :error = Theine.get(cache, {:missing, i})
        end)
      end)
      |> Task.await_many()

      assert %Stats{hits: 800, misses: 36} = Theine.stats(cache)
    end

    test "with stats: false hits and misses read 0 though the tails advance" do
      cache = unique_cache()
      start_supervised!({Theine, [name: cache, stats: false] ++ @bounded})
      Theine.put(cache, :a, 1)

      for _ <- 1..3, do: {:ok, 1} = Theine.get(cache, :a)
      :error = Theine.get(cache, :b)

      assert Theine.stats(cache) == %Stats{hit_rate: 0.0}
      assert Theine.ReadBuffer.hits(Config.get(cache)) == 3
    end
  end

  describe "Stats.read/1 with a read buffer" do
    test "hits is the sum of the stripe tails and the hits counter is ignored" do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: :infinity})

      # A bounded cache's read buffer (specs/03 §Layout): `stripes` regions
      # of `2 + slots` words, the tail first. Built by hand here; M2.4 has
      # the Owner allocate it.
      stripes = 3
      slots = 4
      buffer = :atomics.new(stripes * (2 + slots), signed: false)
      :atomics.put(buffer, 0 * (2 + slots) + 1, 5)
      :atomics.put(buffer, 1 * (2 + slots) + 1, 7)
      :atomics.put(buffer, 2 * (2 + slots) + 1, 11)
      # Heads and slots must not be summed.
      :atomics.put(buffer, 0 * (2 + slots) + 2, 4)
      :atomics.put(buffer, 1 * (2 + slots) + 3, 99)

      config = %{
        Config.get(cache)
        | max_size: 100,
          stripes: stripes,
          read_buffer_slots: slots,
          read_buffer: buffer
      }

      :counters.add(config.counters, Stats.hits(), 1_000)
      :counters.add(config.counters, Stats.misses(), 23)

      assert %Stats{hits: 23, misses: 23, hit_rate: 0.5} = Stats.read(config)
      assert Stats.hits(config) == 23
    end
  end

  describe "field indices" do
    test "match the specs/08 order" do
      assert Stats.fields() == [
               :hits,
               :misses,
               :loads,
               :load_failures,
               :evictions,
               :expirations,
               :refreshes
             ]

      assert Enum.map(Stats.fields(), &Stats.index/1) == Enum.to_list(1..7)

      assert [
               Stats.hits(),
               Stats.misses(),
               Stats.loads(),
               Stats.load_failures(),
               Stats.evictions(),
               Stats.expirations(),
               Stats.refreshes()
             ] == Enum.to_list(1..7)

      assert Stats.field_count() == 7
    end

    test "the Owner allocates one counter per field" do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: :infinity})
      assert %{size: 7} = :counters.info(Config.get(cache).counters)
    end

    test "request_counters is the counters ref, or nil with stats: false" do
      with_stats = unique_cache()
      start_supervised!({Theine, name: with_stats, max_size: :infinity})

      assert %Config{counters: counters, request_counters: counters, hit: counters} =
               Config.get(with_stats)

      assert %{size: 7} = :counters.info(counters)

      without = unique_cache()
      start_supervised!({Theine, name: without, max_size: :infinity, stats: false})
      assert %Config{counters: other, request_counters: nil, hit: nil} = Config.get(without)
      assert %{size: 7} = :counters.info(other)

      bounded = unique_cache()
      start_supervised!({Theine, name: bounded, max_size: 10, stats: false})
      assert %Config{request_counters: nil, hit: {_, _, _, _, _}} = Config.get(bounded)
    end
  end
end
