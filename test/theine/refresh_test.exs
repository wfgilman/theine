defmodule Theine.RefreshTest do
  @moduledoc """
  Refresh-after-write and `refresh/2` (specs/07 §Refresh-after-write,
  §Acceptance; specs/08 §Calls `refresh`, §Telemetry). Time runs on the
  injected clock (specs/06 §Clock), so "t=25" is an `advance/2`, not a
  sleep. Refresh loaders that must overlap with readers are gated: the
  refresh task reports `{:loading, pid, key}` and blocks until the test
  sends `:go`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Theine.Test.Helpers

  alias Theine.{Config, Stats}
  alias Theine.Test.Clock

  # Starts a cache on its own clock with `opts`, puts `key` at t=0.
  defp cache_with(opts, puts \\ [k: :old]) do
    cache = unique_cache()
    start_supervised!({Clock, cache: cache})
    start_supervised!({Theine, [name: cache, max_size: :infinity] ++ opts})
    for {key, value} <- puts, do: :ok = Theine.put(cache, key, value)
    cache
  end

  # A loader that announces itself, waits for `:go`, then returns
  # `result.()`; `calls` counts its calls.
  defp gated(calls, result) do
    test = self()

    fn key ->
      :counters.add(calls, 1, 1)
      send(test, {:loading, self(), key})

      receive do
        :go -> result.()
      end
    end
  end

  # Waits until no refresh is running: the task has deleted its row and
  # exited (specs/07 §Acceptance "No leaks").
  defp await_refreshed(cache) do
    %Config{refreshing: refreshing, task_supervisor: sup} = Config.get(cache)

    assert_eventually(fn ->
      assert :ets.info(refreshing, :size) == 0
      assert Task.Supervisor.children(sup) == []
    end)
  end

  @doc false
  def handle(event, measurements, metadata, %{test: test}) do
    send(test, {:telemetry, event, measurements, metadata})
  end

  describe "refresh_after_write" do
    test "with refresh_after_write: 20 a value written at t=0 is served unchanged at t=25 without waiting" do
      calls = :counters.new(1, [])
      cache = cache_with(refresh_after_write: 20, loader: gated(calls, fn -> {:commit, :new} end))

      Clock.advance(cache, 25)
      # The loader is blocked on `:go`, so this returns before any load.
      assert Theine.get(cache, :k) == {:ok, :old}
      assert_receive {:loading, task, :k}
      assert Theine.get(cache, :k) == {:ok, :old}

      send(task, :go)
      await_refreshed(cache)
      assert Theine.get(cache, :k) == {:ok, :new}
      assert :counters.get(calls, 1) == 1
      assert %Stats{refreshes: 1, loads: 1} = Theine.stats(cache)
    end

    test "an entry younger than refresh_after_write is not refreshed" do
      cache = cache_with(refresh_after_write: 20, loader: fn _ -> flunk("loaded") end)

      Clock.advance(cache, 19)
      assert Theine.get(cache, :k) == {:ok, :old}
      assert %Stats{refreshes: 0, loads: 0} = Theine.stats(cache)
      assert :ets.info(Config.get(cache).refreshing, :size) == 0
    end

    test "100 concurrent readers at t=25 trigger exactly one refresh and the new value is served after it" do
      calls = :counters.new(1, [])
      cache = cache_with(refresh_after_write: 20, loader: gated(calls, fn -> {:commit, :new} end))
      Clock.advance(cache, 25)
      test = self()

      readers =
        for _ <- 1..100 do
          spawn_link(fn -> send(test, {:read, self(), Theine.get(cache, :k)}) end)
        end

      for pid <- readers, do: assert_receive({:read, ^pid, {:ok, :old}}, 5000)
      assert_receive {:loading, task, :k}
      refute_received {:loading, _, _}

      send(task, :go)
      await_refreshed(cache)
      assert Theine.get(cache, :k) == {:ok, :new}
      assert :counters.get(calls, 1) == 1
      assert %Stats{refreshes: 1, loads: 1, hits: 101} = Theine.stats(cache)
    end

    test "a refreshed value is fresh until refresh_after_write passes again" do
      calls = :counters.new(1, [])

      loader = fn _ ->
        :counters.add(calls, 1, 1)
        {:commit, :counters.get(calls, 1)}
      end

      cache = cache_with(refresh_after_write: 20, loader: loader)
      Clock.advance(cache, 20)
      assert Theine.get(cache, :k) == {:ok, :old}
      await_refreshed(cache)

      Clock.advance(cache, 19)
      assert Theine.get(cache, :k) == {:ok, 1}
      Clock.advance(cache, 1)
      assert Theine.get(cache, :k) == {:ok, 1}
      await_refreshed(cache)
      assert Theine.get(cache, :k) == {:ok, 2}
      assert %Stats{refreshes: 2} = Theine.stats(cache)
    end

    @tag :capture_log
    test "a refresh loader that raises leaves the old value and the key refreshable again" do
      calls = :counters.new(1, [])

      loader = fn _ ->
        :counters.add(calls, 1, 1)
        if :counters.get(calls, 1) == 1, do: raise("backend down"), else: {:commit, :new}
      end

      cache = cache_with([refresh_after_write: 20, loader: loader], secret_key: :old)
      Clock.advance(cache, 25)

      log =
        capture_log(fn ->
          assert Theine.get(cache, :secret_key) == {:ok, :old}
          await_refreshed(cache)
        end)

      assert log =~ "refresh failed"
      assert log =~ "backend down"
      refute log =~ "secret_key"
      assert %Stats{refreshes: 1, loads: 1, load_failures: 1} = Theine.stats(cache)

      # Still stale: the next hit serves the old value and refreshes again.
      assert Theine.get(cache, :secret_key) == {:ok, :old}
      await_refreshed(cache)
      assert Theine.get(cache, :secret_key) == {:ok, :new}
      assert %Stats{refreshes: 2, loads: 2, load_failures: 1} = Theine.stats(cache)
    end

    @tag :capture_log
    test "a throw or an exit in the refresh loader also keeps the old value" do
      for failure <- [fn -> throw(:boom) end, fn -> exit(:boom) end] do
        cache = cache_with(refresh_after_write: 20, loader: fn _ -> failure.() end)
        Clock.advance(cache, 25)

        assert Theine.get(cache, :k) == {:ok, :old}
        await_refreshed(cache)
        assert %Stats{load_failures: 1} = Theine.stats(cache)
        assert Theine.get(cache, :k) == {:ok, :old}
      end
    end

    test "{:ignore, v} keeps the old value and releases the key" do
      cache = cache_with(refresh_after_write: 20, loader: fn _ -> {:ignore, :new} end)
      Clock.advance(cache, 25)

      assert Theine.get(cache, :k) == {:ok, :old}
      await_refreshed(cache)
      assert Theine.get(cache, :k) == {:ok, :old}
      await_refreshed(cache)
      assert %Stats{refreshes: 2, loads: 2, load_failures: 0} = Theine.stats(cache)
    end

    test "{:commit, v, ttl: ms} stores the refreshed value with that TTL" do
      cache = cache_with(refresh_after_write: 20, loader: fn _ -> {:commit, :new, ttl: 50} end)
      Clock.advance(cache, 25)

      assert Theine.get(cache, :k) == {:ok, :old}
      await_refreshed(cache)
      assert Theine.ttl(cache, :k) == {:ok, 50}
    end

    test "an entry past both its TTL and refresh_after_write is a miss, not a refresh" do
      cache = cache_with(refresh_after_write: 20, loader: fn _ -> flunk("loaded") end)
      :ok = Theine.put(cache, :k, :old, ttl: 30)

      Clock.advance(cache, 30)
      assert Theine.get(cache, :k) == :error
      assert %Stats{refreshes: 0} = Theine.stats(cache)
    end

    test "a bounded cache records the stale hit and refreshes it" do
      calls = :counters.new(1, [])

      cache =
        cache_with(
          max_size: 100,
          refresh_after_write: 20,
          loader: gated(calls, fn -> {:commit, :new} end)
        )

      Clock.advance(cache, 25)
      assert Theine.get(cache, :k) == {:ok, :old}
      assert_receive {:loading, task, :k}
      send(task, :go)
      await_refreshed(cache)

      assert Theine.get(cache, :k) == {:ok, :new}
      assert %Stats{hits: 2, refreshes: 1} = Theine.stats(cache)
    end

    test "a cache with refresh_after_write and no loader never refreshes on get/2" do
      cache = cache_with(refresh_after_write: 20)
      Clock.advance(cache, 25)

      assert Theine.get(cache, :k) == {:ok, :old}
      assert %Stats{refreshes: 0} = Theine.stats(cache)
    end
  end

  describe "fetch" do
    test "a stale hit in fetch/4 refreshes with the per-call loader, not the cache's" do
      cache = cache_with(refresh_after_write: 20, loader: fn _ -> {:commit, :cache_loader} end)
      Clock.advance(cache, 25)

      assert Theine.fetch(cache, :k, fn _ -> {:commit, :per_call} end) == {:ok, :old}
      await_refreshed(cache)
      assert Theine.get(cache, :k) == {:ok, :per_call}
    end

    test "fetch/4 refreshes in a cache without a loader, where get/2 does not" do
      cache = cache_with(refresh_after_write: 20)
      Clock.advance(cache, 25)

      assert Theine.get(cache, :k) == {:ok, :old}
      assert %Stats{refreshes: 0} = Theine.stats(cache)

      assert Theine.fetch(cache, :k, fn _ -> {:commit, :new} end) == {:ok, :old}
      await_refreshed(cache)
      assert Theine.fetch(cache, :k, fn _ -> flunk("loaded") end) == {:ok, :new}
      assert %Stats{refreshes: 1, hits: 3} = Theine.stats(cache)
    end

    test "fetch_async on a stale hit completes at once with the old value and refreshes" do
      cache = cache_with(refresh_after_write: 20)
      Clock.advance(cache, 25)

      task = Theine.fetch_async(cache, :k, fn _ -> {:commit, :new} end)
      assert task.pid == nil
      assert Task.await(task) == {:ok, :old}
      await_refreshed(cache)
      assert Theine.get(cache, :k) == {:ok, :new}
    end

    test "a miss in fetch/4 loads as before in a refreshing cache" do
      cache = cache_with([refresh_after_write: 20], [])

      assert Theine.fetch(cache, :k, fn _ -> {:commit, 1} end) == {:ok, 1}
      assert %Stats{misses: 1, loads: 1, refreshes: 0} = Theine.stats(cache)
    end
  end

  describe "refresh/2" do
    test "refresh/2 returns {:error, :refreshing} while one runs and {:error, :no_loader} without a loader" do
      calls = :counters.new(1, [])
      cache = cache_with(loader: gated(calls, fn -> {:commit, :new} end))

      assert Theine.refresh(cache, :k) == :ok
      assert_receive {:loading, task, :k}
      assert Theine.refresh(cache, :k) == {:error, :refreshing}
      assert Theine.get(cache, :k) == {:ok, :old}

      send(task, :go)
      await_refreshed(cache)
      assert Theine.get(cache, :k) == {:ok, :new}
      assert :counters.get(calls, 1) == 1
      assert %Stats{refreshes: 1} = Theine.stats(cache)

      without = cache_with([])
      assert Theine.refresh(without, :k) == {:error, :no_loader}
      assert %Stats{refreshes: 0} = Theine.stats(without)
    end

    test "refresh/2 reloads a fresh entry regardless of age, and an absent key" do
      cache = cache_with(loader: fn key -> {:commit, {key, :new}} end)

      assert Theine.refresh(cache, :k) == :ok
      assert Theine.refresh(cache, :absent) == :ok
      await_refreshed(cache)
      assert Theine.get(cache, :k) == {:ok, {:k, :new}}
      assert Theine.get(cache, :absent) == {:ok, {:absent, :new}}
    end

    test "a refresh for a key deleted during the load still stores the value" do
      calls = :counters.new(1, [])
      cache = cache_with(loader: gated(calls, fn -> {:commit, :new} end))

      assert Theine.refresh(cache, :k) == :ok
      assert_receive {:loading, task, :k}
      :ok = Theine.delete(cache, :k)
      assert Theine.get(cache, :k) == :error

      send(task, :go)
      await_refreshed(cache)
      assert Theine.get(cache, :k) == {:ok, :new}
    end

    test "a refresh that cannot start gives the key back" do
      cache = cache_with(loader: fn _ -> {:commit, :new} end)
      %Config{task_supervisor: sup, refreshing: refreshing} = Config.get(cache)
      :ok = Supervisor.terminate_child(Theine.Supervisor.name(cache), Theine.TaskSupervisor)
      refute Process.whereis(sup)

      assert catch_exit(Theine.refresh(cache, :k))
      assert :ets.info(refreshing, :size) == 0

      # A stale hit swallows the same failure: the reader still gets its value.
      stale = cache_with(refresh_after_write: 20, loader: fn _ -> {:commit, :new} end)
      :ok = Supervisor.terminate_child(Theine.Supervisor.name(stale), Theine.TaskSupervisor)
      Clock.advance(stale, 25)
      assert Theine.get(stale, :k) == {:ok, :old}
      assert :ets.info(Config.get(stale).refreshing, :size) == 0
      assert %Stats{refreshes: 0} = Theine.stats(stale)
    end
  end

  describe "telemetry" do
    setup do
      handler = {__MODULE__, make_ref()}

      events = [
        [:theine, :refresh, :exception]
        | for(s <- [:start, :stop, :exception], do: [:theine, :load, s])
      ]

      test = self()

      :ok =
        :telemetry.attach_many(handler, events, &__MODULE__.handle/4, %{test: test})

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "a refresh emits load start and stop keyed by cache only" do
      cache = cache_with(loader: fn _ -> {:commit, :new} end)

      :ok = Theine.refresh(cache, :k)
      await_refreshed(cache)

      assert_received {:telemetry, [:theine, :load, :start], _, %{cache: ^cache} = start}
      assert_received {:telemetry, [:theine, :load, :stop], _, %{cache: ^cache}}
      assert Map.delete(start, :telemetry_span_context) == %{cache: cache}
      refute_received {:telemetry, [:theine, :refresh, :exception], _, %{cache: ^cache}}
    end

    @tag :capture_log
    test "a failed refresh emits [:theine, :refresh, :exception] with kind, reason and stacktrace" do
      cache = cache_with(loader: fn _ -> raise ArgumentError, "bad" end)

      :ok = Theine.refresh(cache, :k)
      await_refreshed(cache)

      assert_received {:telemetry, [:theine, :load, :exception], _, %{cache: ^cache}}

      assert_received {:telemetry, [:theine, :refresh, :exception], %{system_time: _},
                       %{
                         cache: ^cache,
                         kind: :error,
                         reason: %ArgumentError{},
                         stacktrace: [_ | _]
                       } =
                         metadata}

      refute Map.has_key?(metadata, :key)
    end
  end
end
