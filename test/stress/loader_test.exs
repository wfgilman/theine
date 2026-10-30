defmodule Theine.Stress.LoaderTest do
  # The loader soak and its leak check (specs/07 §Acceptance "Exactly-once"
  # and "No leaks"). Each round starts 1_000 processes at once, so it runs
  # alone. All randomness is drawn in the test process before a round
  # starts, so the ExUnit seed reproduces a failing round.
  use ExUnit.Case, async: false

  import Theine.Test.Helpers

  alias Theine.{Config, Stats}
  alias Theine.Test.Clock

  @moduletag :stress
  @moduletag :capture_log
  @moduletag timeout: 300_000

  @rounds 100
  @fetchers 1_000

  # Exactly-once soak: at most this many fresh keys per round, and claimant
  # delays and fetcher start offsets of 0..@max_delay ms.
  @max_keys 20
  @max_delay 50

  # Mixed soak: one pool of keys for every round, so later rounds find the
  # values earlier ones stored, now stale or expired on the injected clock.
  @pool 64
  @refresh_after 20
  @ttl 15
  @max_op_delay 20
  @results [:commit, :commit, :commit, :ttl, :ignore, :raise, :throw, :exit]
  @ops [:fetch, :fetch, :fetch, :fetch, :fetch_async, :fetch_async] ++
         [:get, :get, :get, :refresh, :put, :delete]

  # Spawns one process per item of `plan`, starts them together, and
  # returns `fun.(item)` of each, in plan order.
  defp run_all(plan, fun) do
    test = self()

    pids =
      for item <- plan do
        spawn_link(fn ->
          receive do
            :go -> send(test, {:done, self(), fun.(item)})
          end
        end)
      end

    Enum.each(pids, &send(&1, :go))

    for pid <- pids do
      assert_receive {:done, ^pid, result}, 10_000
      result
    end
  end

  defp random_delay(max), do: :rand.uniform(max + 1) - 1

  # Waits until no refresh or async fetch is running, then checks the
  # loader tables: nothing a finished load leaves behind.
  defp assert_no_leaks(cache) do
    %Config{
      inflight: inflight,
      waiters: waiters,
      refreshing: refreshing,
      task_supervisor: sup
    } = Config.get(cache)

    assert_eventually(fn -> Task.Supervisor.children(sup) == [] end, 10_000)
    assert :ets.tab2list(refreshing) == []
    assert :ets.tab2list(inflight) == []
    assert :ets.tab2list(waiters) == []
  end

  test "exactly-once holds across 100 rounds of 1_000 fetchers on random keys with random claimant delays" do
    cache = unique_cache()
    start_supervised!({Theine, name: cache, max_size: :infinity})

    loaded = Enum.sum(for round <- 1..@rounds, do: exactly_once_round(cache, round))

    assert_no_leaks(cache)
    assert %Stats{loads: ^loaded, load_failures: 0} = Theine.stats(cache)
  end

  # One round on keys no earlier round used: every fetcher waits its random
  # offset, then fetches a random key of the round through a loader that
  # sleeps that key's random delay. The offsets spread the fetchers over
  # the claim, the load, the commit and the release, so a round has
  # claimants, waiters, fetchers that register late and fetchers that hit.
  # Every fetcher gets its key's value, and every key fetched is loaded
  # exactly once, the others never. Returns the number of keys loaded.
  defp exactly_once_round(cache, round) do
    keys = :rand.uniform(@max_keys)
    delays = List.to_tuple(for _ <- 1..keys, do: random_delay(@max_delay))
    calls = :counters.new(keys, [:write_concurrency])

    loader = fn {^round, i} = key ->
      :counters.add(calls, i, 1)
      Process.sleep(elem(delays, i - 1))
      {:commit, {:value, key}}
    end

    plan = for _ <- 1..@fetchers, do: {{round, :rand.uniform(keys)}, random_delay(@max_delay)}

    outcomes =
      run_all(plan, fn {key, offset} ->
        Process.sleep(offset)
        {key, Theine.fetch(cache, key, loader)}
      end)

    assert Enum.reject(outcomes, fn {key, outcome} -> outcome == {:ok, {:value, key}} end) == []

    fetched = MapSet.new(plan, fn {{^round, i}, _} -> i end)
    expected = for i <- 1..keys, do: if(i in fetched, do: 1, else: 0)
    assert for(i <- 1..keys, do: :counters.get(calls, i)) == expected

    MapSet.size(fetched)
  end

  # The cache's loader, used by refreshes: the key `{i, result, delay}`
  # carries what the load does.
  def keyed_loader({_, result, delay} = key), do: load(key, result, delay)

  defp load(key, result, delay) do
    Process.sleep(delay)

    case result do
      :commit -> {:commit, {:value, key}}
      :ttl -> {:commit, {:value, key}, ttl: @ttl}
      :ignore -> {:ignore, {:value, key}}
      :raise -> raise "load failed"
      :throw -> throw(:load_failed)
      :exit -> exit(:load_failed)
    end
  end

  test "after the soak inflight, waiters and refreshing are empty and the task supervisor has no children" do
    cache = unique_cache()
    start_supervised!({Clock, cache: cache})

    start_supervised!(
      {Theine,
       name: cache,
       max_size: :infinity,
       refresh_after_write: @refresh_after,
       loader: &__MODULE__.keyed_loader/1}
    )

    pool =
      List.to_tuple(
        for i <- 1..@pool, do: {i, Enum.random(@results), random_delay(@max_op_delay)}
      )

    outcomes =
      Enum.flat_map(1..@rounds, fn _ ->
        plan = for _ <- 1..@fetchers, do: random_op(pool)
        outcomes = run_all(plan, &perform(cache, &1))
        # Ages every stored value, so the next round has stale hits that
        # refresh and expired entries that load again.
        Clock.advance(cache, random_delay(@refresh_after + @ttl))
        Enum.zip(plan, outcomes)
      end)

    assert Enum.reject(outcomes, fn {op, outcome} -> expected?(op, outcome) end) == []

    # The soak reached every path that holds a loader row: waiters that
    # timed out, failed loads in claimants and waiters, async fetches, and
    # refreshes, started both by stale hits and by refresh/2.
    seen = MapSet.new(outcomes, fn {op, outcome} -> {elem(op, 0), shape(outcome)} end)

    for path <- [
          fetch: :timeout,
          fetch: :load_failed,
          fetch: :caught,
          fetch_async: :timeout,
          fetch_async: :load_failed,
          fetch_async: :exit,
          refresh: :ok,
          refresh: :refreshing
        ] do
      assert path in seen
    end

    assert_no_leaks(cache)

    %Stats{loads: loads, load_failures: failures, refreshes: refreshes} = Theine.stats(cache)
    assert failures > 0 and loads > failures
    refreshed = Enum.count(outcomes, &match?({{:refresh, _}, :ok}, &1))
    assert refreshes > refreshed
  end

  defp random_op(pool) do
    key = elem(pool, :rand.uniform(@pool) - 1)

    case Enum.random(@ops) do
      fetch when fetch in [:fetch, :fetch_async] ->
        opts = if :rand.uniform(2) == 1, do: [], else: [timeout: :rand.uniform(@max_op_delay)]

        {fetch, key, Enum.random(@results), random_delay(@max_op_delay), opts,
         random_delay(@max_op_delay)}

      op ->
        {op, key, random_delay(@max_op_delay)}
    end
  end

  defp perform(cache, {:fetch, key, result, delay, opts, offset}) do
    Process.sleep(offset)
    Theine.fetch(cache, key, fn k -> load(k, result, delay) end, opts)
  catch
    kind, reason -> {:caught, kind, reason}
  end

  defp perform(cache, {:fetch_async, key, result, delay, opts, offset}) do
    Process.sleep(offset)

    cache
    |> Theine.fetch_async(key, fn k -> load(k, result, delay) end, opts)
    |> Task.yield(5_000)
  end

  defp perform(cache, {op, key, offset}) do
    Process.sleep(offset)

    case op do
      :get -> Theine.get(cache, key)
      :refresh -> Theine.refresh(cache, key)
      :put -> Theine.put(cache, key, {:value, key})
      :delete -> Theine.delete(cache, key)
    end
  end

  # A fetch returns its own key's value or one of the failures specs/07
  # names; nothing else, and never another key's value.
  defp expected?({:fetch, key, _, _, _, _}, outcome), do: fetched?(key, outcome)

  defp expected?({:fetch_async, key, _, _, _, _}, {:ok, outcome}), do: fetched?(key, outcome)
  defp expected?({:fetch_async, _, _, _, _, _}, {:exit, _}), do: true
  defp expected?({:get, key, _}, outcome), do: outcome in [{:ok, {:value, key}}, :error]
  defp expected?({:refresh, _, _}, outcome), do: outcome in [:ok, {:error, :refreshing}]
  defp expected?({op, _, _}, outcome) when op in [:put, :delete], do: outcome == :ok
  defp expected?(_, _), do: false

  defp fetched?(key, {:ok, {:value, key}}), do: true
  defp fetched?(_, {:error, :timeout}), do: true
  defp fetched?(_, {:error, {:load_failed, _}}), do: true
  defp fetched?(_, {:caught, kind, _}), do: kind in [:error, :throw, :exit]
  defp fetched?(_, _), do: false

  defp shape({:ok, outcome}) when is_tuple(outcome), do: shape(outcome)
  defp shape({:error, {:load_failed, _}}), do: :load_failed
  defp shape({:error, reason}) when is_atom(reason), do: reason
  defp shape(other) when is_tuple(other), do: elem(other, 0)
  defp shape(other), do: other
end
