defmodule Theine.ExpiryTest do
  @moduledoc """
  Expiry driven by the injected clock (specs/06 §Semantics, §Clock,
  §Acceptance): lazily on the read path (specs/01 §Expired read), and by
  the maintenance sweep over the `Theine.Expiry` index (specs/06 §Index;
  specs/04 §The pass step 4).
  """

  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.{Config, Entry, Expiry, Maintenance, Stats}
  alias Theine.Test.Clock

  doctest Expiry

  setup do
    cache = unique_cache()
    start_supervised!({Clock, cache: cache, at: 1_000})
    # The long interval keeps the timer out of the mailbox counts below.
    start_supervised!(
      {Theine, name: cache, max_size: :infinity, test_hooks: true, maintenance_interval: 60_000}
    )

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

  describe "the sweep (specs/06 §Index; specs/04 §The pass step 4)" do
    test "with maintenance running and no reads an expired entry leaves the table within one maintenance_interval" do
      cache = unique_cache()
      start_supervised!({Clock, cache: cache, at: 0})
      start_supervised!({Theine, name: cache, max_size: 100, maintenance_interval: 20})
      attach_pass_handler(cache)

      Theine.put(cache, :a, 1, ttl: 10)
      Theine.put(cache, :forever, 2)
      assert_eventually(fn -> Maintenance.info(cache).expiring == 1 end)

      # Every pass that read the clock before it moved has reported by the
      # time info/1 answers (one sender, messages in order), so the first
      # pass event after the flush is from a pass that saw the new time: the
      # next interval pass, at most one maintenance_interval away.
      Clock.advance(cache, 10)
      Maintenance.info(cache)
      flush_passes()

      assert_receive {:pass, %{expired: 1, reads: 0}}, 1_000
      assert :ets.lookup(cache, :a) == []
      assert %{expiring: 0, size: 1} = Maintenance.info(cache)
      assert expirations(cache) == 1
      assert Theine.get(cache, :forever) == {:ok, 2}
    end

    test "100_000 entries expiring at once are removed over several passes of at most expire_batch each without waiting for the timer" do
      cache = unique_cache()
      n = 100_000
      batch = Config.new!(name: cache, max_size: n).expire_batch
      start_supervised!({Clock, cache: cache, at: 0})
      # The interval timer never fires during the test: only the follow-ups move the sweep on.
      start_supervised!({Theine, name: cache, max_size: n, maintenance_interval: 60_000})
      attach_pass_handler(cache)

      for i <- 1..n, do: Theine.put(cache, i, i, ttl: 10)
      assert_eventually(fn -> Maintenance.info(cache).expiring == n end, 10_000)
      Clock.advance(cache, 10)
      Maintenance.info(cache)
      flush_passes()

      Theine.run_maintenance(cache)
      counts = await_expired(n, [])

      full = div(n, batch)
      assert counts == List.duplicate(batch, full) ++ [n - full * batch]
      assert :ets.info(cache, :size) == 0
      assert %{expiring: 0, size: 0, weighted_size: 0} = Maintenance.info(cache)
      assert expirations(cache) == n
    end

    test "a put racing the sweep of the previous version keeps the new value" do
      cache = unique_cache()
      start_gated(cache)

      Theine.put(cache, :a, :v1, ttl: 10)
      [{:a, :v1, id1, _, _, 10}] = :ets.lookup(cache, :a)
      assert %{expiring: 1} = Maintenance.info(cache)
      Clock.advance(cache, 10)

      # The sweep is held at its start with v1 due; v2 lands in the table
      # and its :put waits in the mailbox behind the pass.
      held = hold_sweep(cache)
      Theine.put(cache, :a, :v2)
      release_sweep(cache, held)

      assert [{:a, :v2, id2, _, _, :infinity}] = :ets.lookup(cache, :a)
      assert id2 > id1
      assert Theine.get(cache, :a) == {:ok, :v2}
      assert {:ok, {:a, ^id2, _, _, _, :infinity}} = Maintenance.policy_row(cache, :a)
      assert %{size: 1, expiring: 0} = Maintenance.info(cache)
      assert expirations(cache) == 0
    end

    test "under real interleavings a put racing the sweep always keeps the new value", %{
      cache: cache
    } do
      for round <- 1..200 do
        key = {:race, round}
        Theine.put(cache, key, :old, ttl: 1)
        Clock.advance(cache, 1)

        sweep = Task.async(fn -> Theine.run_maintenance(cache) end)
        writer = Task.async(fn -> Theine.put(cache, key, :new) end)
        [:ok, :ok] = Task.await_many([sweep, writer])

        assert Theine.get(cache, key) == {:ok, :new}, "round #{round} lost the new value"
      end

      assert_eventually(fn -> Maintenance.info(cache).pending == 0 end)
      assert %{size: 200, expiring: 0} = Maintenance.info(cache)
    end

    test "an expires_at rewritten in place before its event arrives keeps the entry" do
      cache = unique_cache()
      start_gated(cache)

      Theine.put(cache, :a, :v1, ttl: 10)
      [{:a, :v1, id, _, _, 10}] = :ets.lookup(cache, :a)
      Clock.advance(cache, 10)

      # What expire/3 does (specs/06 §Semantics): the table first, the
      # same-id :put after. Here the sweep runs in between.
      held = hold_sweep(cache)
      true = :ets.update_element(cache, :a, {6, 50})
      release_sweep(cache, held)

      assert {:ok, {:a, ^id, _, _, _, 50}} = Maintenance.policy_row(cache, :a)
      assert %{size: 1, expiring: 1} = Maintenance.info(cache)
      assert Theine.get(cache, :a) == {:ok, :v1}
      assert expirations(cache) == 0

      # The index moved with it: swept at the new time.
      Clock.advance(cache, 40)
      Theine.run_maintenance(cache)
      assert :ets.lookup(cache, :a) == []
      assert %{size: 0, expiring: 0} = Maintenance.info(cache)
      assert expirations(cache) == 1
    end

    test "an unbounded cache sweeps expired entries too", %{cache: cache} do
      Theine.put(cache, :a, 1, ttl: 10)
      Theine.put(cache, :b, 2, ttl: 20)
      Theine.put(cache, :c, 3)
      assert %{expiring: 2, segments: nil} = Maintenance.info(cache)

      Clock.advance(cache, 10)
      Theine.run_maintenance(cache)
      assert :ets.lookup(cache, :a) == []
      assert %{size: 2, weighted_size: 2, expiring: 1} = Maintenance.info(cache)

      Clock.advance(cache, 10)
      Theine.run_maintenance(cache)
      assert [{:c, 3, _, _, _, :infinity}] = :ets.tab2list(cache)
      assert %{size: 1, expiring: 0} = Maintenance.info(cache)
      assert expirations(cache) == 2
    end

    test "an overwrite moves the key's index row, and an overwrite without a ttl removes it", %{
      cache: cache
    } do
      Theine.put(cache, :a, 1, ttl: 10)
      Theine.put(cache, :a, 2, ttl: 100)
      assert %{expiring: 1} = Maintenance.info(cache)

      Clock.advance(cache, 10)
      Theine.run_maintenance(cache)
      assert Theine.get(cache, :a) == {:ok, 2}

      Theine.put(cache, :a, 3)
      assert %{expiring: 0, size: 1} = Maintenance.info(cache)
      Clock.advance(cache, 100)
      Theine.run_maintenance(cache)
      assert Theine.get(cache, :a) == {:ok, 3}
    end

    test "a delete or an expired read removes the index row", %{cache: cache} do
      Theine.put(cache, :a, 1, ttl: 10)
      Theine.put(cache, :b, 2, ttl: 10)
      assert %{expiring: 2} = Maintenance.info(cache)

      Theine.delete(cache, :a)
      assert %{expiring: 1} = Maintenance.info(cache)

      Clock.advance(cache, 10)
      assert Theine.get(cache, :b) == :error
      assert %{expiring: 0, size: 0} = Maintenance.info(cache)
    end

    test "a maintenance restart re-indexes every entry with a finite expires_at", %{cache: cache} do
      for i <- 1..50, do: Theine.put(cache, i, i, ttl: i)
      for i <- 51..60, do: Theine.put(cache, i, i)
      assert %{expiring: 50} = Maintenance.info(cache)

      old = Process.whereis(Maintenance.name(cache))
      Process.exit(old, :kill)
      assert_eventually(fn -> Process.whereis(Maintenance.name(cache)) not in [nil, old] end)
      assert %{size: 60, expiring: 50} = Maintenance.info(cache)

      Clock.advance(cache, 25)
      Theine.run_maintenance(cache)
      assert %{size: 35, expiring: 25} = Maintenance.info(cache)
      assert Enum.all?(1..25, &(:ets.lookup(cache, &1) == []))
      assert Enum.all?(26..60, &(Theine.get(cache, &1) == {:ok, &1}))
    end

    test "clear/1 empties the index", %{cache: cache} do
      Theine.put(cache, :a, 1, ttl: 10)
      Theine.clear(cache)
      assert %{expiring: 0, size: 0} = Maintenance.info(cache)

      Theine.put(cache, :a, 2, ttl: 100)
      Clock.advance(cache, 10)
      Theine.run_maintenance(cache)
      assert Theine.get(cache, :a) == {:ok, 2}
      assert %{expiring: 1, size: 1} = Maintenance.info(cache)
    end
  end

  describe "expire/3, persist/2 and ttl/2 (specs/06 §Semantics)" do
    test "expire/3 moves the entry in the index and it is swept at the new time with the old row gone",
         %{cache: cache} do
      Theine.put(cache, :a, :v, ttl: 10)
      [{:a, :v, id, 1, 1_000, 1_010}] = :ets.lookup(cache, :a)

      assert Theine.expire(cache, :a, 50) == true
      assert [{:a, :v, ^id, 1, 1_000, 1_050}] = :ets.lookup(cache, :a)
      assert {:ok, {:a, ^id, _, _, 1, 1_050}} = Maintenance.policy_row(cache, :a)
      assert %{expiring: 1, size: 1} = Maintenance.info(cache)

      # The old time passes with nothing indexed there.
      Clock.advance(cache, 10)
      Theine.run_maintenance(cache)
      assert [{:a, :v, ^id, _, _, 1_050}] = :ets.lookup(cache, :a)
      assert expirations(cache) == 0

      # The sweep, not a read, removes it at the new time.
      Clock.advance(cache, 40)
      Theine.run_maintenance(cache)
      assert :ets.lookup(cache, :a) == []
      assert %{expiring: 0, size: 0} = Maintenance.info(cache)
      assert expirations(cache) == 1
    end

    test "expire/3 sets an expiry on an entry that had none and can shorten one", %{cache: cache} do
      Theine.put(cache, :a, 1)
      Theine.put(cache, :b, 2, ttl: 1_000)

      assert Theine.expire(cache, :a, 20)
      assert Theine.expire(cache, :b, 10)
      assert %{expiring: 2} = Maintenance.info(cache)

      Clock.advance(cache, 10)
      Theine.run_maintenance(cache)
      assert :ets.lookup(cache, :b) == []
      Clock.advance(cache, 10)
      Theine.run_maintenance(cache)
      assert :ets.lookup(cache, :a) == []
      assert %{expiring: 0, size: 0} = Maintenance.info(cache)
    end

    test "persist/2 removes the index row and the entry never expires", %{cache: cache} do
      Theine.put(cache, :a, :v, ttl: 10)
      assert %{expiring: 1} = Maintenance.info(cache)

      assert Theine.persist(cache, :a) == true
      assert [{:a, :v, _, _, _, :infinity}] = :ets.lookup(cache, :a)
      assert {:ok, {:a, _, _, _, _, :infinity}} = Maintenance.policy_row(cache, :a)
      assert %{expiring: 0, size: 1} = Maintenance.info(cache)

      Clock.advance(cache, 1_000_000)
      Theine.run_maintenance(cache)
      assert Theine.get(cache, :a) == {:ok, :v}
      assert Theine.ttl(cache, :a) == {:ok, :infinity}
    end

    test "ttl/2 returns remaining ms, :infinity, or :error", %{cache: cache} do
      Theine.put(cache, :a, 1, ttl: 100)
      Theine.put(cache, :b, 2)
      assert Theine.ttl(cache, :a) == {:ok, 100}
      assert Theine.ttl(cache, :b) == {:ok, :infinity}
      assert Theine.ttl(cache, :missing) == :error

      Clock.advance(cache, 30)
      assert Theine.ttl(cache, :a) == {:ok, 70}
      Clock.advance(cache, 70)
      assert Theine.ttl(cache, :a) == :error

      # Not a read in the stats, and not a remover: the expired entry is
      # left for a reader or the sweep.
      assert [{:a, 1, _, _, _, 1_100}] = :ets.lookup(cache, :a)
      assert %Stats{hits: 0, misses: 0, expirations: 0} = Theine.stats(cache)
    end

    test "expire/3 on an absent key returns false", %{cache: cache} do
      assert Theine.expire(cache, :missing, 10) == false
      assert Theine.persist(cache, :missing) == false
      refute :ets.member(cache, :missing)

      # An expired entry is absent too, and stays expired.
      Theine.put(cache, :a, 1, ttl: 10)
      Clock.advance(cache, 10)
      assert Theine.expire(cache, :a, 1_000) == false
      assert Theine.persist(cache, :a) == false
      assert [{:a, 1, _, _, _, 1_010}] = :ets.lookup(cache, :a)
      assert {:ok, {:a, _, _, _, _, 1_010}} = Maintenance.policy_row(cache, :a)
      assert Theine.get(cache, :a) == :error
    end

    test "expire/3 rejects an expiry that is not a positive integer or :infinity", %{cache: cache} do
      Theine.put(cache, :a, 1)

      for bad <- [0, -1, 1.5, :never] do
        assert_raise ArgumentError, ~r/positive number of milliseconds or :infinity/, fn ->
          Theine.expire(cache, :a, bad)
        end
      end

      assert Theine.ttl(cache, :a) == {:ok, :infinity}
    end

    test "expire/3 is not an access: the policy row keeps its place" do
      cache = unique_cache()
      start_supervised!({Clock, cache: cache, at: 0})
      start_supervised!({Theine, name: cache, max_size: 100, maintenance_interval: 60_000})

      Theine.put(cache, :a, 1)
      Theine.put(cache, :b, 2)
      # The window holds one entry, so b's arrival moved a to probation.
      {:ok, {:a, id, :probation, seq, 1, :infinity}} = Maintenance.policy_row(cache, :a)

      assert Theine.expire(cache, :a, 50)
      assert {:ok, {:a, ^id, :probation, ^seq, 1, 50}} = Maintenance.policy_row(cache, :a)
    end

    test "an expired read that loses its delete to expire/3 leaves the entry and its row", %{
      cache: cache
    } do
      Theine.put(cache, :a, :v, ttl: 10)
      [{:a, :v, id, _, _, 1_010} = seen] = :ets.lookup(cache, :a)

      # A reader saw `seen` expired; expire/3 rewrote it in place before the
      # reader's delete_object, which then missed. The reader's
      # {:removed, :a, id} arrives after the same-id :put.
      assert Theine.expire(cache, :a, 100)
      assert Entry.expired(Config.get(cache), seen) == :error

      assert [{:a, :v, ^id, _, _, 1_100}] = :ets.lookup(cache, :a)
      assert {:ok, {:a, ^id, _, _, _, 1_100}} = Maintenance.policy_row(cache, :a)
      assert %{size: 1, expiring: 1} = Maintenance.info(cache)

      Clock.advance(cache, 100)
      Theine.run_maintenance(cache)
      assert :ets.lookup(cache, :a) == []
      assert %{size: 0, expiring: 0} = Maintenance.info(cache)
    end

    test "under real interleavings a delete racing expire/3 always removes the key", %{
      cache: cache
    } do
      for round <- 1..300 do
        key = {:race, round}
        Theine.put(cache, key, :v, ttl: 1_000)

        expirer = Task.async(fn -> Theine.expire(cache, key, 5_000) end)
        deleter = Task.async(fn -> Theine.delete(cache, key) end)
        [_, :ok] = Task.await_many([expirer, deleter])

        assert :ets.lookup(cache, key) == [], "round #{round} kept a deleted key"
      end

      assert_eventually(fn -> Maintenance.info(cache).pending == 0 end)
      assert %{size: 0, expiring: 0} = Maintenance.info(cache)
    end

    test "under real interleavings puts and expires on one key leave the policy on the table's version",
         %{cache: cache} do
      keys = for round <- 1..200, do: {:race, round}

      for key <- keys do
        Theine.put(cache, key, :old, ttl: 100)

        [
          fn -> Theine.put(cache, key, :new, ttl: 300) end,
          fn -> Theine.expire(cache, key, 500) end,
          fn -> Theine.expire(cache, key, 700) end,
          fn -> Theine.persist(cache, key) end
        ]
        |> Enum.map(&Task.async/1)
        |> Task.await_many()
      end

      assert_eventually(fn -> Maintenance.info(cache).pending == 0 end)

      for key <- keys do
        [{^key, _, id, _, _, expires_at}] = :ets.lookup(cache, key)
        assert {:ok, {^key, ^id, _, _, _, ^expires_at}} = Maintenance.policy_row(cache, key)
      end

      finite = Enum.count(keys, &is_integer(:ets.lookup_element(cache, &1, 6)))
      assert %{size: 200, expiring: ^finite} = Maintenance.info(cache)
    end
  end

  defp expirations(cache), do: :counters.get(Config.get(cache).counters, Stats.expirations())

  # A bounded cache whose policy calls can be held (specs/10 §Required
  # helpers `Theine.Test.Policy`), on a test clock at 0.
  defp start_gated(cache) do
    start_supervised!({Clock, cache: cache, at: 0})

    start_supervised!(
      {Theine,
       name: cache,
       max_size: 100,
       test_hooks: true,
       policy_module: Theine.Test.Policy,
       maintenance_interval: 60_000}
    )
  end

  # Runs a pass in a task and returns once the pass is held at the start of
  # its sweep, after step 1's flush.
  defp hold_sweep(cache) do
    :ok = Theine.Test.Policy.gate(cache, :expire)
    runner = Task.async(fn -> Theine.run_maintenance(cache) end)
    assert_receive {Theine.Test.Policy, ^cache, :gated, :expire, pid}
    {pid, runner}
  end

  defp release_sweep(cache, {pid, runner}) do
    Theine.Test.Policy.release(cache, pid)
    :ok = Task.await(runner)
  end

  defp attach_pass_handler(cache) do
    handler = {__MODULE__, cache}

    :ok =
      :telemetry.attach(
        handler,
        [:theine, :maintenance, :pass],
        &__MODULE__.handle_pass/4,
        %{test: self(), cache: cache}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def handle_pass(_event, measurements, %{cache: cache}, %{cache: cache, test: test}),
    do: send(test, {:pass, measurements})

  def handle_pass(_event, _measurements, _metadata, _config), do: :ok

  defp flush_passes do
    receive do
      {:pass, _} -> flush_passes()
    after
      0 -> :ok
    end
  end

  # The `expired` count of each pass until `left` more entries have gone.
  defp await_expired(left, counts) when left <= 0, do: Enum.reverse(counts)

  defp await_expired(left, counts) do
    assert_receive {:pass, %{expired: expired}}, 1_000
    await_expired(left - expired, [expired | counts])
  end
end
