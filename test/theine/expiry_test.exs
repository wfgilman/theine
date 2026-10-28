defmodule Theine.ExpiryTest do
  @moduledoc """
  Lazy expiry on the read path driven by the injected clock (specs/06
  §Semantics bullets 1–3, §Clock, §Acceptance; specs/01 §Expired read). The
  sweep arrives in M3.1; nothing here waits for a maintenance pass.
  """

  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.{Config, Entry, Maintenance}
  alias Theine.Test.Clock

  setup do
    cache = unique_cache()
    start_supervised!({Clock, cache: cache, at: 1_000})
    start_supervised!({Theine, name: cache, max_size: :infinity, test_hooks: true})
    %{cache: cache}
  end

  test "put/4 stamps written_at and expires_at from the injected clock", %{cache: cache} do
    Theine.put(cache, :a, 1, ttl: 10)
    assert [{:a, 1, _, 1, 1_000, 1_010}] = :ets.lookup(cache, :a)

    Clock.advance(cache, 5)
    Theine.put(cache, :b, 2)
    assert [{:b, 2, _, 1, 1_005, :infinity}] = :ets.lookup(cache, :b)
  end

  test "entry with 10 ms TTL is readable at 0 ms and :error at 10 ms with the clock advanced and no pass",
       %{cache: cache} do
    Theine.put(cache, :a, 1, ttl: 10)
    assert Theine.get(cache, :a) == {:ok, 1}

    Clock.advance(cache, 9)
    assert Theine.get(cache, :a) == {:ok, 1}

    Clock.advance(cache, 1)
    assert Theine.get(cache, :a) == :error
    assert Theine.get(cache, :a, :default) == :default
    assert :ets.lookup(cache, :a) == []

    # Only the reader acted: no maintenance pass ran.
    assert %{passes: 0} = Maintenance.info(cache)
  end

  test "the cache-wide expire_after_write default expires on read too" do
    cache = unique_cache()
    start_supervised!({Clock, cache: cache, at: 0})
    start_supervised!({Theine, name: cache, max_size: :infinity, expire_after_write: 50})

    Theine.put(cache, :a, 1)
    Theine.put(cache, :forever, 2, ttl: :infinity)
    Clock.advance(cache, 50)

    assert Theine.get(cache, :a) == :error
    assert Theine.get(cache, :forever) == {:ok, 2}
  end

  test "with maintenance paused the reader deletes the expired tuple", %{cache: cache} do
    Theine.put(cache, :a, 1, ttl: 10)
    assert_eventually(fn -> Maintenance.info(cache).pending == 0 end)
    maintenance = Process.whereis(Maintenance.name(cache))

    :ok = Maintenance.pause(cache)
    Clock.advance(cache, 10)

    assert Theine.get(cache, :a) == :error
    assert :ets.lookup(cache, :a) == []

    # The {:removed, :a, id} event is queued, not applied, while paused.
    config = Config.get(cache)
    assert :atomics.get(config.pending, 1) == 1
    assert {:message_queue_len, 1} = Process.info(maintenance, :message_queue_len)

    :ok = Maintenance.resume(cache)
    assert Maintenance.policy_row(cache, :a) == :error
    assert %{pending: 0, size: 0} = Maintenance.info(cache)
  end

  test "an expired read counts a miss and an expiration", %{cache: cache} do
    counters = Config.get(cache).counters
    Theine.put(cache, :a, 1, ttl: 10)
    Clock.advance(cache, 10)

    misses = :counters.get(counters, 2)
    expirations = :counters.get(counters, 6)
    assert Theine.get(cache, :a) == :error
    assert :counters.get(counters, 2) == misses + 1
    assert :counters.get(counters, 6) == expirations + 1
  end

  describe "put racing an expired read" do
    test "the reader deletes only the tuple it saw, so a newer version survives", %{cache: cache} do
      # The reader observed v1 (already expired) just before the writer
      # replaced it: its delete_object names v1's exact tuple.
      Theine.put(cache, :a, :v1, ttl: 10)
      [{:a, :v1, id1, _, _, _} = v1] = :ets.lookup(cache, :a)
      Clock.advance(cache, 10)

      Theine.put(cache, :a, :v2)
      assert Entry.expired(Config.get(cache), v1) == :error

      assert Theine.get(cache, :a) == {:ok, :v2}
      assert [{:a, :v2, id2, _, _, :infinity}] = :ets.lookup(cache, :a)
      assert id2 > id1

      # The stale {:removed, :a, id1} does not disturb the policy's v2 row.
      Theine.run_maintenance(cache)
      assert {:ok, {:a, ^id2, _, _, _, :infinity}} = Maintenance.policy_row(cache, :a)
      assert Theine.size(cache) == 1
    end

    test "under real interleavings the new value is always in place afterwards", %{cache: cache} do
      for round <- 1..200 do
        key = {:race, round}
        Theine.put(cache, key, :old, ttl: 1)
        Clock.advance(cache, 1)

        reader = Task.async(fn -> Theine.get(cache, key) end)
        writer = Task.async(fn -> Theine.put(cache, key, :new) end)
        [read, :ok] = Task.await_many([reader, writer])

        assert read in [:error, {:ok, :new}]
        assert Theine.get(cache, key) == {:ok, :new}, "round #{round} lost the new value"
      end

      assert_eventually(fn -> Maintenance.info(cache).pending == 0 end)
      Theine.run_maintenance(cache)
      assert Theine.size(cache) == 200
    end
  end
end
