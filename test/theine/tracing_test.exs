defmodule Theine.TracingTest do
  @moduledoc """
  The hot-path budget (specs/01 §Acceptance): the exact multiset of calls
  into `:ets`, `:atomics`, `:counters` and `:persistent_term` that `get/2`
  makes. Policy-disabled multisets (specs/08 §Acceptance): with
  `max_size: :infinity` there is no read buffer, so no `:atomics` call.
  """

  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.Test.Trace

  @modules [:ets, :atomics, :counters, :persistent_term]

  setup do
    cache = unique_cache()
    start_supervised!({Theine, name: cache, max_size: :infinity})
    Theine.put(cache, :present, 1)
    %{cache: cache}
  end

  test "hit performs exactly persistent_term.get, ets.lookup, counters.add", %{cache: cache} do
    calls = Trace.calls(@modules, fn -> {:ok, 1} = Theine.get(cache, :present) end)

    assert calls == %{
             {:persistent_term, :get, 1} => 1,
             {:ets, :lookup, 2} => 1,
             {:counters, :add, 3} => 1
           }
  end

  test "miss performs exactly persistent_term.get, ets.lookup, counters.add", %{cache: cache} do
    calls = Trace.calls(@modules, fn -> :error = Theine.get(cache, :absent) end)

    assert calls == %{
             {:persistent_term, :get, 1} => 1,
             {:ets, :lookup, 2} => 1,
             {:counters, :add, 3} => 1
           }
  end

  test "get/3 adds nothing to the hit path", %{cache: cache} do
    calls = Trace.calls(@modules, fn -> 1 = Theine.get(cache, :present, 0) end)

    assert calls == %{
             {:persistent_term, :get, 1} => 1,
             {:ets, :lookup, 2} => 1,
             {:counters, :add, 3} => 1
           }
  end

  test "expired read performs exactly persistent_term.get, ets.lookup, ets.delete_object, atomics.add_get, counters.add ×2",
       %{cache: cache} do
    # The injected clock (specs/06 §Clock) is an Agent call, outside the
    # traced modules, so the multiset is the production one.
    start_supervised!({Theine.Test.Clock, cache: cache})
    Theine.put(cache, :expiring, 1, ttl: 10)
    Theine.Test.Clock.advance(cache, 10)

    calls = Trace.calls(@modules, fn -> :error = Theine.get(cache, :expiring) end)

    # delete_object of the exact tuple, add_get on `pending` for the
    # {:removed, key, id} event, misses and expirations (specs/01 §Expired read).
    assert calls == %{
             {:persistent_term, :get, 1} => 1,
             {:ets, :lookup, 2} => 1,
             {:ets, :delete_object, 2} => 1,
             {:atomics, :add_get, 3} => 1,
             {:counters, :add, 3} => 2
           }

    assert :ets.lookup(cache, :expiring) == []
  end

  test "put performs persistent_term.get, atomics.add_get ×2, ets.insert", %{cache: cache} do
    calls = Trace.calls(@modules, fn -> :ok = Theine.put(cache, :new, 1) end)

    # One add_get for the id, one for `pending` (specs/01 §Write path, specs/03).
    assert calls == %{
             {:persistent_term, :get, 1} => 1,
             {:atomics, :add_get, 3} => 2,
             {:ets, :insert, 2} => 1
           }
  end

  test "put_new of a new key performs persistent_term.get, atomics.add_get ×2, ets.insert_new",
       %{cache: cache} do
    calls = Trace.calls(@modules, fn -> :ok = Theine.put_new(cache, :new, 1) end)

    assert calls == %{
             {:persistent_term, :get, 1} => 1,
             {:atomics, :add_get, 3} => 2,
             {:ets, :insert_new, 2} => 1
           }
  end

  test "put_new of a present key adds one ets.lookup and touches pending not at all",
       %{cache: cache} do
    calls =
      Trace.calls(@modules, fn -> {:error, :exists} = Theine.put_new(cache, :present, 2) end)

    # The one add_get is the id; no `pending` increment means no event.
    assert calls == %{
             {:persistent_term, :get, 1} => 1,
             {:atomics, :add_get, 3} => 1,
             {:ets, :insert_new, 2} => 1,
             {:ets, :lookup, 2} => 1
           }
  end

  test "delete performs persistent_term.get, ets.lookup, ets.delete_object, ets.lookup_element, atomics.add_get",
       %{cache: cache} do
    calls = Trace.calls(@modules, fn -> :ok = Theine.delete(cache, :present) end)

    # The lookup_element checks that no expire/3 rewrote the tuple in place
    # under the delete (specs/06 §Decisions M3.2).
    assert calls == %{
             {:persistent_term, :get, 1} => 1,
             {:ets, :lookup, 2} => 1,
             {:ets, :delete_object, 2} => 1,
             {:ets, :lookup_element, 4} => 1,
             {:atomics, :add_get, 3} => 1
           }
  end

  test "delete of an absent key performs persistent_term.get, ets.lookup", %{cache: cache} do
    calls = Trace.calls(@modules, fn -> :ok = Theine.delete(cache, :absent) end)

    assert calls == %{{:persistent_term, :get, 1} => 1, {:ets, :lookup, 2} => 1}
  end

  describe "stats: false" do
    setup do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: :infinity, stats: false})
      Theine.put(cache, :present, 1)
      %{nostats: cache}
    end

    test "hit performs no :counters call", %{nostats: cache} do
      calls = Trace.calls(@modules, fn -> {:ok, 1} = Theine.get(cache, :present) end)

      assert calls == %{{:persistent_term, :get, 1} => 1, {:ets, :lookup, 2} => 1}
    end

    test "miss performs no :counters call", %{nostats: cache} do
      calls = Trace.calls(@modules, fn -> :error = Theine.get(cache, :absent) end)

      assert calls == %{{:persistent_term, :get, 1} => 1, {:ets, :lookup, 2} => 1}
    end

    test "expired read drops the misses op and keeps the expirations op", %{nostats: cache} do
      start_supervised!({Theine.Test.Clock, cache: cache})
      Theine.put(cache, :expiring, 1, ttl: 10)
      Theine.Test.Clock.advance(cache, 10)

      calls = Trace.calls(@modules, fn -> :error = Theine.get(cache, :expiring) end)

      assert calls == %{
               {:persistent_term, :get, 1} => 1,
               {:ets, :lookup, 2} => 1,
               {:ets, :delete_object, 2} => 1,
               {:atomics, :add_get, 3} => 1,
               {:counters, :add, 3} => 1
             }
    end
  end

  describe "bounded cache" do
    # One stripe so every scheduler records into the same ring; a long
    # interval so only `:drain` messages move the head while the test counts.
    @bounded [
      max_size: 1_000,
      stripes: 1,
      read_buffer_slots: 8,
      drain_threshold: 4,
      maintenance_interval: 60_000,
      test_hooks: true
    ]

    setup do
      cache = unique_cache()
      start_supervised!({Theine, [name: cache] ++ @bounded})
      Theine.put(cache, :present, 1)
      Theine.run_maintenance(cache)
      %{bounded: cache}
    end

    test "bounded hit performs exactly persistent_term.get, ets.lookup, atomics.add_get, atomics.put",
         %{bounded: cache} do
      calls = Trace.calls(@modules, fn -> {:ok, 1} = Theine.get(cache, :present) end)

      # The read buffer claims a sequence (add_get on the tail) and writes
      # the id into its slot without reading the head (specs/03 §record/2,
      # §Decisions M2.8b); the hit count comes from the tails, so no
      # :counters call (specs/08 §Stats).
      assert calls == %{
               {:persistent_term, :get, 1} => 1,
               {:ets, :lookup, 2} => 1,
               {:atomics, :add_get, 3} => 1,
               {:atomics, :put, 3} => 1
             }
    end

    test "bounded hit with stats: false performs the same multiset" do
      cache = unique_cache()
      start_supervised!({Theine, [name: cache, stats: false] ++ @bounded})
      Theine.put(cache, :present, 1)
      Theine.run_maintenance(cache)

      calls = Trace.calls(@modules, fn -> {:ok, 1} = Theine.get(cache, :present) end)

      assert calls == %{
               {:persistent_term, :get, 1} => 1,
               {:ets, :lookup, 2} => 1,
               {:atomics, :add_get, 3} => 1,
               {:atomics, :put, 3} => 1
             }
    end

    test "bounded miss performs exactly persistent_term.get, ets.lookup, counters.add",
         %{bounded: cache} do
      calls = Trace.calls(@modules, fn -> :error = Theine.get(cache, :absent) end)

      assert calls == %{
               {:persistent_term, :get, 1} => 1,
               {:ets, :lookup, 2} => 1,
               {:counters, :add, 3} => 1
             }
    end

    test "every drain_threshold-th bounded hit adds exactly one compare_exchange",
         %{bounded: cache} do
      # Sequences 0..2 are not multiples of the threshold of 4 minus one;
      # the fourth hit claims sequence 3, so `rem(t + 1, 4) == 0` and the
      # reader flips the drain flag and sends `:drain` (specs/03 §record/2
      # step 4).
      for _ <- 1..3, do: {:ok, 1} = Theine.get(cache, :present)
      assert %{read_buffer: %{lag: 3}} = Theine.Maintenance.info(cache)

      calls = Trace.calls(@modules, fn -> {:ok, 1} = Theine.get(cache, :present) end)

      assert calls == %{
               {:persistent_term, :get, 1} => 1,
               {:ets, :lookup, 2} => 1,
               {:atomics, :add_get, 3} => 1,
               {:atomics, :put, 3} => 1,
               {:atomics, :compare_exchange, 4} => 1
             }

      # The `:drain` it sent runs a pass that empties the stripe.
      assert_eventually(fn ->
        assert %{read_buffer: %{lag: 0}} = Theine.Maintenance.info(cache)
      end)
    end

    test "a bounded hit past a lagging drainer still writes its slot: add_get, put, no head read",
         %{bounded: cache} do
      # Paused, the maintenance process consumes neither the `:drain` sent
      # at sequence 3 nor anything else, so the head stays at 0 and the
      # ring of 8 has been lapped by sequence 8. The reader does not look:
      # it overwrites the slot of sequence 0, which is the drop (specs/03
      # §Decisions M2.8b). Sequence 8 is not a trigger (`rem(9, 4) != 0`).
      Theine.Maintenance.pause(cache)
      for _ <- 1..8, do: {:ok, 1} = Theine.get(cache, :present)

      calls = Trace.calls(@modules, fn -> {:ok, 1} = Theine.get(cache, :present) end)

      assert calls == %{
               {:persistent_term, :get, 1} => 1,
               {:ets, :lookup, 2} => 1,
               {:atomics, :add_get, 3} => 1,
               {:atomics, :put, 3} => 1
             }

      # Sequence 11 is a trigger; the flag is still set from sequence 3,
      # so the compare_exchange fails and nothing more is sent.
      for _ <- 1..2, do: {:ok, 1} = Theine.get(cache, :present)
      calls = Trace.calls(@modules, fn -> {:ok, 1} = Theine.get(cache, :present) end)

      assert calls == %{
               {:persistent_term, :get, 1} => 1,
               {:ets, :lookup, 2} => 1,
               {:atomics, :add_get, 3} => 1,
               {:atomics, :put, 3} => 1,
               {:atomics, :compare_exchange, 4} => 1
             }

      Theine.Maintenance.resume(cache)
      # Every hit claimed a sequence, overwritten or not (specs/03 §Hits from the tails).
      assert %Theine.Stats{hits: 12} = Theine.stats(cache)
    end
  end

  describe "refresh_after_write" do
    # The clock is outside the traced modules (an Agent call or the BIF), so
    # these are the production multisets.
    @hit %{
      {:persistent_term, :get, 1} => 1,
      {:ets, :lookup, 2} => 1,
      {:counters, :add, 3} => 1
    }

    defp refresh_cache(opts) do
      cache = unique_cache()
      start_supervised!({Theine.Test.Clock, cache: cache})
      start_supervised!({Theine, [name: cache, max_size: :infinity] ++ opts})
      Theine.put(cache, :present, 1)
      cache
    end

    test "hit on a cache without refresh_after_write is unchanged" do
      cache = refresh_cache(loader: fn _ -> {:commit, 2} end)
      Theine.Test.Clock.advance(cache, 1_000_000)

      assert Trace.calls(@modules, fn -> {:ok, 1} = Theine.get(cache, :present) end) == @hit
    end

    test "hit on a cache with refresh_after_write and no loader is unchanged" do
      cache = refresh_cache(refresh_after_write: 20)
      Theine.Test.Clock.advance(cache, 25)

      assert Trace.calls(@modules, fn -> {:ok, 1} = Theine.get(cache, :present) end) == @hit
    end

    test "a fresh hit with refresh_after_write adds no traced call" do
      cache = refresh_cache(refresh_after_write: 20, loader: fn _ -> {:commit, 2} end)
      Theine.Test.Clock.advance(cache, 19)

      assert Trace.calls(@modules, fn -> {:ok, 1} = Theine.get(cache, :present) end) == @hit
    end

    test "a stale hit adds the claim, the task's pid and the refreshes counter op" do
      test = self()

      loader = fn _ ->
        send(test, :loading)
        {:commit, 2}
      end

      cache = refresh_cache(refresh_after_write: 20, loader: loader)
      Theine.put(cache, :warm, 1)
      Theine.Test.Clock.advance(cache, 20)
      # The first refresh in the VM loads modules lazily, and code loading
      # reads :persistent_term; refresh another key once so that only the
      # refresh path itself is counted.
      {:ok, 1} = Theine.get(cache, :warm)
      assert_receive :loading

      calls = Trace.calls(@modules, fn -> {:ok, 1} = Theine.get(cache, :present) end)
      assert_receive :loading

      assert calls == %{
               {:persistent_term, :get, 1} => 1,
               {:ets, :lookup, 2} => 1,
               {:ets, :insert_new, 2} => 1,
               {:ets, :select_replace, 2} => 1,
               {:counters, :add, 3} => 2
             }
    end

    test "a stale hit while a refresh runs adds one ets.insert_new and one ets.lookup" do
      test = self()

      loader = fn _ ->
        send(test, {:loading, self()})

        receive do
          :go -> {:commit, 2}
        end
      end

      cache = refresh_cache(refresh_after_write: 20, loader: loader)
      Theine.Test.Clock.advance(cache, 20)
      {:ok, 1} = Theine.get(cache, :present)
      assert_receive {:loading, task}

      # The losing claim looks the row up and finds its task alive
      # (specs/07 §Decisions M4.4b); `Process.alive?/1` is not traced.
      calls = Trace.calls(@modules, fn -> {:ok, 1} = Theine.get(cache, :present) end)
      send(task, :go)

      assert calls == %{
               {:persistent_term, :get, 1} => 1,
               {:ets, :lookup, 2} => 2,
               {:ets, :insert_new, 2} => 1,
               {:counters, :add, 3} => 1
             }
    end
  end

  test "an oversized put touches nothing", %{cache: cache} do
    config = %{Theine.Config.get(cache) | max_size: 1}
    calls = Trace.calls(@modules, fn -> :ok = Theine.Entry.put(config, :big, 1, weight: 2) end)

    assert calls == %{}
  end
end
