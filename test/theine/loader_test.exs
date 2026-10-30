defmodule Theine.LoaderTest do
  @moduledoc """
  Single-flight `fetch/2,4` (specs/07 §The loader function, §Single-flight;
  specs/08 §Calls). Loaders that must overlap with other fetchers are
  gated: the claimant reports `{:loading, pid, key}` and blocks until the
  test sends `:go`, so a test can wait until every other fetcher has
  registered as a waiter before the load completes.
  """

  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.{Config, Stats}

  setup do
    cache = unique_cache()
    start_supervised!({Theine, name: cache, max_size: :infinity})
    %{cache: cache}
  end

  # Starts `n` linked processes that each fetch `key` once and report
  # `{:fetched, pid, outcome}`; a raise, throw or exit in the caller is
  # reported as `{:caught, kind, reason}`.
  defp fetchers(cache, key, loader, n, opts \\ []) do
    test = self()

    for _ <- 1..n do
      spawn_link(fn ->
        outcome =
          try do
            Theine.fetch(cache, key, loader, opts)
          catch
            kind, reason -> {:caught, kind, reason}
          end

        send(test, {:fetched, self(), outcome})
      end)
    end
  end

  defp collect(pids) do
    Map.new(pids, fn pid ->
      assert_receive {:fetched, ^pid, outcome}, 5000
      {pid, outcome}
    end)
  end

  # A loader that announces itself, waits for `:go`, then returns `result.()`.
  defp gated(result) do
    test = self()

    fn key ->
      send(test, {:loading, self(), key})

      receive do
        :go -> result.()
      end
    end
  end

  # Waits until the claimant is loading and every other fetcher of the
  # claim is registered, then lets the load finish. Returns the claimant.
  defp release_when_waiting(cache, key, waiters) do
    assert_receive {:loading, claimant, ^key}, 5000
    table = Config.get(cache).waiters
    assert_eventually(fn -> :ets.info(table, :size) == waiters end, 5000)
    send(claimant, :go)
    claimant
  end

  defp assert_loader_tables_empty(cache) do
    %Config{inflight: inflight, waiters: waiters} = Config.get(cache)
    assert :ets.tab2list(inflight) == []
    assert :ets.tab2list(waiters) == []
  end

  describe "single flight" do
    test "1_000 concurrent fetches on one missing key run the loader once and all receive the value",
         %{cache: cache} do
      calls = :counters.new(1, [])

      loader =
        gated(fn ->
          :counters.add(calls, 1, 1)
          {:commit, :loaded}
        end)

      pids = fetchers(cache, :k, loader, 1_000)
      release_when_waiting(cache, :k, 999)
      outcomes = collect(pids)

      assert Enum.all?(Map.values(outcomes), &(&1 == {:ok, :loaded}))
      assert :counters.get(calls, 1) == 1
      refute_received {:loading, _, _}
      assert Theine.get(cache, :k) == {:ok, :loaded}
      assert_loader_tables_empty(cache)
      assert %Stats{loads: 1, load_failures: 0, misses: 1_000} = Theine.stats(cache)
    end

    test "{:ignore, v} is returned to every waiter and the key stays absent", %{cache: cache} do
      pids = fetchers(cache, :k, gated(fn -> {:ignore, :not_found} end), 50)
      release_when_waiting(cache, :k, 49)

      assert collect(pids) |> Map.values() |> Enum.uniq() == [{:ok, :not_found}]
      assert Theine.get(cache, :k) == :error
      assert_loader_tables_empty(cache)
      Theine.run_maintenance(cache)
      assert Theine.size(cache) == 0
      assert %Stats{loads: 1, load_failures: 0} = Theine.stats(cache)
    end

    test "a raising loader re-raises in the claimant, every waiter gets {:error, {:load_failed, _}}, nothing is cached, inflight and waiters are empty",
         %{cache: cache} do
      pids = fetchers(cache, :k, gated(fn -> raise "boom" end), 50)
      claimant = release_when_waiting(cache, :k, 49)
      outcomes = collect(pids)

      assert {:caught, :error, %RuntimeError{message: "boom"}} = outcomes[claimant]

      for {pid, outcome} <- outcomes, pid != claimant do
        assert outcome == {:error, {:load_failed, %RuntimeError{message: "boom"}}}
      end

      assert Theine.get(cache, :k) == :error
      assert_loader_tables_empty(cache)
      assert %Stats{loads: 1, load_failures: 1} = Theine.stats(cache)

      # The key is not stuck: the next fetch claims and loads.
      assert Theine.fetch(cache, :k, fn _ -> {:commit, 1} end) == {:ok, 1}
      assert_loader_tables_empty(cache)
    end

    test "a throw or an exit reaches the claimant as such and the waiters as {:nocatch, v} or the exit reason",
         %{cache: cache} do
      cases = [
        {fn -> throw(:thrown) end, :throw, :thrown, {:nocatch, :thrown}},
        {fn -> exit(:gone) end, :exit, :gone, :gone},
        # An Erlang error reaches the claimant raw, as from any call, and
        # the waiters normalized to its exception.
        {fn -> :erlang.error(:badarg) end, :error, :badarg,
         %ArgumentError{message: "argument error"}}
      ]

      for {{body, kind, reason, waiter_reason}, i} <- Enum.with_index(cases) do
        pids = fetchers(cache, i, gated(body), 10)
        claimant = release_when_waiting(cache, i, 9)
        outcomes = collect(pids)

        assert outcomes[claimant] == {:caught, kind, reason}

        for {pid, outcome} <- outcomes, pid != claimant do
          assert outcome == {:error, {:load_failed, waiter_reason}}
        end

        assert Theine.get(cache, i) == :error
        assert_loader_tables_empty(cache)
      end

      assert %Stats{loads: 3, load_failures: 3} = Theine.stats(cache)
    end

    test "a loader returning anything else raises ArgumentError in the claimant and fails the waiters",
         %{cache: cache} do
      pids = fetchers(cache, :k, gated(fn -> {:ok, 1} end), 5)
      claimant = release_when_waiting(cache, :k, 4)
      outcomes = collect(pids)

      assert {:caught, :error, %ArgumentError{message: message}} = outcomes[claimant]
      assert message =~ "must return {:commit, value}"

      for {pid, outcome} <- outcomes, pid != claimant do
        assert {:error, {:load_failed, %ArgumentError{}}} = outcome
      end

      assert Theine.get(cache, :k) == :error
      assert_loader_tables_empty(cache)
    end
  end

  describe "fetch/2,4" do
    test "a hit returns the cached value and never calls the loader", %{cache: cache} do
      Theine.put(cache, :k, :cached)

      assert Theine.fetch(cache, :k, fn _ -> flunk("loader called on a hit") end) ==
               {:ok, :cached}

      assert %Stats{hits: 1, misses: 0, loads: 0} = Theine.stats(cache)
    end

    test "{:commit, v, ttl: ms} stores the value with that TTL", %{cache: cache} do
      assert Theine.fetch(cache, :k, fn :k -> {:commit, 1, ttl: 60_000} end) == {:ok, 1}
      assert {:ok, ms} = Theine.ttl(cache, :k)
      assert ms > 0 and ms <= 60_000

      Theine.run_maintenance(cache)
      assert Theine.size(cache) == 1
    end

    test "per-call loader wins over the cache loader" do
      cache = unique_cache()

      start_supervised!(
        {Theine, name: cache, max_size: 100, loader: fn _ -> {:commit, :cache} end}
      )

      assert Theine.fetch(cache, :a, fn _ -> {:commit, :call} end) == {:ok, :call}
      assert Theine.fetch(cache, :b) == {:ok, :cache}
      assert Theine.fetch(cache, :c, nil) == {:ok, :cache}
      assert Theine.get(cache, :a) == {:ok, :call}
    end

    test "fetch/2 without a loader raises ArgumentError", %{cache: cache} do
      assert_raise ArgumentError, ~r/has no loader/, fn -> Theine.fetch(cache, :k) end
      assert_raise ArgumentError, ~r/has no loader/, fn -> Theine.fetch(cache, :k, nil) end

      # Raised at call time, hit or miss.
      Theine.put(cache, :k, 1)
      assert_raise ArgumentError, ~r/has no loader/, fn -> Theine.fetch(cache, :k) end
      assert_loader_tables_empty(cache)
    end

    test "invalid loaders and options raise ArgumentError", %{cache: cache} do
      assert_raise ArgumentError, ~r/arity 1/, fn -> Theine.fetch(cache, :k, fn -> 1 end) end

      assert_raise ArgumentError, ~r/:timeout/, fn ->
        Theine.fetch(cache, :k, fn _ -> {:commit, 1} end, timeout: -1)
      end

      assert_raise ArgumentError, ~r/:bogus/, fn ->
        Theine.fetch(cache, :k, fn _ -> {:commit, 1} end, bogus: 1)
      end
    end

    test "the claimant's exception keeps its stacktrace", %{cache: cache} do
      try do
        Theine.fetch(cache, :k, fn _ -> raise_from_loader() end)
        flunk("fetch did not raise")
      rescue
        e in RuntimeError ->
          assert e.message == "from loader"
          assert [{__MODULE__, :raise_from_loader, 0, _} | _] = __STACKTRACE__
      end

      assert_loader_tables_empty(cache)
    end
  end

  defp raise_from_loader, do: raise("from loader")

  # Only the attached cache's loads: the async tests' caches emit the same
  # events.
  def handle_load(event, measurements, %{cache: cache} = metadata, %{cache: cache, test: test}) do
    send(test, {:telemetry, event, measurements, metadata})
  end

  def handle_load(_event, _measurements, _metadata, _config), do: :ok

  describe "telemetry" do
    setup %{cache: cache} do
      handler = {__MODULE__, cache}
      events = for suffix <- [:start, :stop, :exception], do: [:theine, :load, suffix]

      :ok =
        :telemetry.attach_many(handler, events, &__MODULE__.handle_load/4, %{
          cache: cache,
          test: self()
        })

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "a load emits start and stop, a failed one start and exception, keyed by cache only",
         %{cache: cache} do
      {:ok, 1} = Theine.fetch(cache, :secret, fn _ -> {:commit, 1} end)

      assert_received {:telemetry, [:theine, :load, :start], %{monotonic_time: _}, start}
      assert_received {:telemetry, [:theine, :load, :stop], %{duration: d}, stop}
      assert is_integer(d) and d >= 0
      assert Map.delete(start, :telemetry_span_context) == %{cache: cache}
      assert Map.delete(stop, :telemetry_span_context) == %{cache: cache}

      # A hit loads nothing.
      {:ok, 1} = Theine.fetch(cache, :secret, fn _ -> {:commit, 2} end)
      refute_received {:telemetry, _, _, _}

      assert_raise RuntimeError, fn -> Theine.fetch(cache, :other, fn _ -> raise "x" end) end
      assert_received {:telemetry, [:theine, :load, :start], _, _}

      assert_received {:telemetry, [:theine, :load, :exception], %{duration: _},
                       %{cache: ^cache, kind: :error, reason: %RuntimeError{}}}

      refute_received {:telemetry, [:theine, :load, :stop], _, _}
    end
  end
end
