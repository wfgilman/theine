defmodule Theine.LoaderTest do
  @moduledoc """
  Single-flight `fetch/2,4` (specs/07 §The loader function, §Single-flight;
  specs/08 §Calls). Loaders that must overlap with other fetchers are
  gated: the claimant reports `{:loading, pid, key}` and blocks until the
  test sends `:go`, so a test can wait until every other fetcher has
  registered as a waiter before the load completes. The waiter edge cases
  stop a fetcher between two steps of the algorithm with
  `Theine.Test.LoaderHook`, so each interleaving runs every time.
  """

  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.{Config, Stats}
  alias Theine.Test.LoaderHook

  setup do
    cache = unique_cache()
    start_supervised!({Theine, name: cache, max_size: :infinity})
    %{cache: cache}
  end

  # Starts `n` linked processes that each fetch `key` once and report
  # `{:fetched, pid, outcome}`; a raise, throw or exit in the caller is
  # reported as `{:caught, kind, reason}`. With `pause:` each arms that
  # `Theine.Test.LoaderHook` point first.
  defp fetchers(cache, key, loader, n, opts \\ [], pause \\ nil) do
    test = self()

    for _ <- 1..n do
      spawn_link(fn ->
        if pause, do: LoaderHook.pause_at(pause, test)

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
    claimant = await_waiters(cache, key, waiters)
    send(claimant, :go)
    claimant
  end

  defp await_waiters(cache, key, waiters) do
    assert_receive {:loading, claimant, ^key}, 5000
    table = Config.get(cache).waiters
    assert_eventually(fn -> :ets.info(table, :size) == waiters end, 5000)
    claimant
  end

  # A gated loader that counts its calls in `calls`.
  defp counted(calls, value) do
    gated(fn ->
      :counters.add(calls, 1, 1)
      {:commit, value}
    end)
  end

  defp kill(pid) do
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5000
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

  describe "claimant death" do
    test "claimant killed mid-load gives waiters {:error, {:load_failed, :killed}} and the next fetch claims successfully",
         %{cache: cache} do
      pids = fetchers(cache, :k, gated(fn -> {:commit, :never} end), 10)
      claimant = await_waiters(cache, :k, 9)
      kill(claimant)
      outcomes = collect(pids -- [claimant])

      assert outcomes |> Map.values() |> Enum.uniq() == [{:error, {:load_failed, :killed}}]
      # The dead claim went with the first waiter's :DOWN.
      assert_loader_tables_empty(cache)
      assert Theine.get(cache, :k) == :error

      assert Theine.fetch(cache, :k, fn _ -> {:commit, 1} end) == {:ok, 1}
      assert_loader_tables_empty(cache)
      # The killed load never completed.
      assert %Stats{loads: 1, load_failures: 0} = Theine.stats(cache)
    end

    test "a claim left by a claimant killed with no waiters is reclaimed by the next fetch",
         %{cache: cache} do
      [claimant] = fetchers(cache, :k, gated(fn -> {:commit, :never} end), 1)
      assert_receive {:loading, ^claimant, :k}, 5000
      kill(claimant)
      assert [{:k, ^claimant, _}] = :ets.tab2list(Config.get(cache).inflight)

      # The fetch monitors the dead claimant, sees :noproc, drops the claim
      # and claims the key itself.
      assert Theine.fetch(cache, :k, fn _ -> {:commit, 1} end) == {:ok, 1}
      assert Theine.get(cache, :k) == {:ok, 1}
      assert_loader_tables_empty(cache)
    end

    test "a claimant killed after committing leaves waiters with the committed value",
         %{cache: cache} do
      test = self()

      loader = fn key ->
        send(test, {:loading, self(), key})

        receive do
          :commit -> :ok = Theine.put(cache, key, :committed)
        end

        send(test, :committed)

        receive do
          :go -> {:commit, :never}
        end
      end

      pids = fetchers(cache, :k, loader, 5)
      claimant = await_waiters(cache, :k, 4)
      send(claimant, :commit)
      assert_receive :committed, 5000
      kill(claimant)

      assert collect(pids -- [claimant]) |> Map.values() |> Enum.uniq() == [{:ok, :committed}]
      assert_loader_tables_empty(cache)
    end

    test "a claimant that exits :normal after committing leaves waiters with the value",
         %{cache: cache} do
      # The library's claimant always notifies before it returns, so this
      # one is played by hand: it holds a claim, commits, and exits without
      # releasing or notifying.
      claimant =
        spawn(fn ->
          receive do
            :commit -> :ok = Theine.put(cache, :k, :committed)
          end
        end)

      true = :ets.insert_new(Config.get(cache).inflight, {:k, claimant, make_ref()})
      pids = fetchers(cache, :k, fn _ -> flunk("loader called") end, 5)
      assert_eventually(fn -> :ets.info(Config.get(cache).waiters, :size) == 5 end, 5000)
      send(claimant, :commit)

      assert collect(pids) |> Map.values() |> Enum.uniq() == [{:ok, :committed}]
      assert_loader_tables_empty(cache)
    end

    test "a claimant that exits :normal without committing sends its waiters to load once",
         %{cache: cache} do
      claimant =
        spawn(fn ->
          receive do
            :exit -> :ok
          end
        end)

      true = :ets.insert_new(Config.get(cache).inflight, {:k, claimant, make_ref()})
      calls = :counters.new(1, [])

      loader = fn _ ->
        :counters.add(calls, 1, 1)
        {:commit, :loaded}
      end

      pids = fetchers(cache, :k, loader, 20)
      assert_eventually(fn -> :ets.info(Config.get(cache).waiters, :size) == 20 end, 5000)
      send(claimant, :exit)

      assert collect(pids) |> Map.values() |> Enum.uniq() == [{:ok, :loaded}]
      assert :counters.get(calls, 1) == 1
      assert_loader_tables_empty(cache)
    end
  end

  describe "timeout" do
    test "a waiter with timeout: 10 and a 100 ms loader returns {:error, :timeout} and leaves no waiter row",
         %{cache: cache} do
      test = self()

      loader = fn key ->
        send(test, {:loading, self(), key})
        Process.sleep(100)
        {:commit, :slow}
      end

      [claimant] = fetchers(cache, :k, loader, 1)
      assert_receive {:loading, ^claimant, :k}, 5000

      # This process is the waiter.
      assert Theine.fetch(cache, :k, loader, timeout: 10) == {:error, :timeout}
      assert :ets.tab2list(Config.get(cache).waiters) == []

      assert collect([claimant]) == %{claimant => {:ok, :slow}}
      # The claimant has released and notified (its :fetched follows any
      # notification to this process), and none arrived.
      refute_received {:theine_loaded, _, _}
      refute_received {:DOWN, _, _, _, _}
      assert_loader_tables_empty(cache)
    end

    test "a notification sent to a timed-out waiter's alias is dropped", %{cache: cache} do
      test = self()
      [claimant] = fetchers(cache, :k, gated(fn -> {:commit, :v} end), 1)
      assert_receive {:loading, ^claimant, :k}, 5000

      waiter =
        spawn_link(fn ->
          LoaderHook.pause_at(:registered, test)
          send(test, {:fetched, self(), Theine.fetch(cache, :k, & &1, timeout: 10)})

          receive do
            :report -> send(test, {:mailbox, self(), Process.info(self(), :messages)})
          end
        end)

      assert_receive {:paused, ^waiter, :registered, :k}, 5000
      [{{:k, _}, ^waiter, mon}] = :ets.tab2list(Config.get(cache).waiters)
      LoaderHook.resume(waiter)
      assert_receive {:fetched, ^waiter, {:error, :timeout}}, 5000

      # What a claimant that read the row just before the waiter deleted it
      # would send, arriving after the waiter gave up.
      send(mon, {:theine_loaded, mon, {:ok, :late}})
      send(claimant, :go)
      assert collect([claimant]) == %{claimant => {:ok, :v}}

      send(waiter, :report)
      assert_receive {:mailbox, ^waiter, {:messages, []}}, 5000
    end

    test "a waiter whose timeout fires as the claimant notifies returns the value",
         %{cache: cache} do
      [claimant] = fetchers(cache, :k, gated(fn -> {:commit, :v} end), 1)
      assert_receive {:loading, ^claimant, :k}, 5000
      [waiter] = fetchers(cache, :k, & &1, 1, [timeout: 10], :timed_out)
      assert_receive {:paused, ^waiter, :timed_out, :k}, 5000

      # The waiter's row is still in place, so the claimant notifies it.
      send(claimant, :go)
      assert collect([claimant]) == %{claimant => {:ok, :v}}

      LoaderHook.resume(waiter)
      assert collect([waiter]) == %{waiter => {:ok, :v}}
      assert_loader_tables_empty(cache)
    end
  end

  describe "late registration" do
    setup %{cache: cache} do
      calls = :counters.new(1, [])
      [claimant] = fetchers(cache, :k, counted(calls, :v), 1)
      assert_receive {:loading, ^claimant, :k}, 5000
      %{calls: calls, claimant: claimant}
    end

    # Starts a second fetcher paused at `point`, lets the claimant finish,
    # then resumes the fetcher and returns its outcome.
    defp finish_claimant_while_paused(cache, claimant, calls, point) do
      [fetcher] = fetchers(cache, :k, counted(calls, :again), 1, [], point)
      assert_receive {:paused, ^fetcher, ^point, :k}, 5000

      send(claimant, :go)
      assert collect([claimant]) == %{claimant => {:ok, :v}}

      LoaderHook.resume(fetcher)
      refute_receive {:loading, ^fetcher, :k}, 50
      collect([fetcher])[fetcher]
    end

    test "a waiter registering after the claimant's release retries and hits the committed value",
         %{cache: cache, calls: calls, claimant: claimant} do
      # Monitoring the claimant, row not yet inserted: the release reads no
      # row for it, the double-check finds the claim gone, the retry hits.
      assert finish_claimant_while_paused(cache, claimant, calls, :monitored) == {:ok, :v}
      assert :counters.get(calls, 1) == 1
      assert_loader_tables_empty(cache)
      # The waiter's retry is its second get.
      assert %Stats{hits: 1, misses: 2, loads: 1} = Theine.stats(cache)
    end

    test "a waiter that registered before the release but double-checks after it takes the notification",
         %{cache: cache, calls: calls, claimant: claimant} do
      assert finish_claimant_while_paused(cache, claimant, calls, :registered) == {:ok, :v}
      assert :counters.get(calls, 1) == 1
      assert_loader_tables_empty(cache)
      # Answered from the mailbox: no second get.
      assert %Stats{hits: 0, misses: 2, loads: 1} = Theine.stats(cache)
      refute_received {:theine_loaded, _, _}
    end

    test "a fetcher whose claim lost to a claimant that then finished retries and hits",
         %{cache: cache, calls: calls, claimant: claimant} do
      # The claim failed while the claimant held the key; the lookup after
      # its release finds no claimant.
      assert finish_claimant_while_paused(cache, claimant, calls, :claim_lost) == {:ok, :v}
      assert :counters.get(calls, 1) == 1
      assert_loader_tables_empty(cache)
      assert %Stats{hits: 1, misses: 2, loads: 1} = Theine.stats(cache)
    end

    test "a fetcher that missed before the commit and claims after the release does not load again",
         %{cache: cache, calls: calls, claimant: claimant} do
      # Its insert_new succeeds once the claim is released; the claimant's
      # value is in the table by then.
      assert finish_claimant_while_paused(cache, claimant, calls, :claim) == {:ok, :v}
      assert :counters.get(calls, 1) == 1
      assert_loader_tables_empty(cache)
      assert %Stats{loads: 1} = Theine.stats(cache)
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

  defp assert_no_tasks(cache) do
    sup = Config.get(cache).task_supervisor
    assert_eventually(fn -> Task.Supervisor.children(sup) == [] end, 5000)
  end

  describe "fetch_async" do
    test "ten fetch_async tasks for one key run the loader once", %{cache: cache} do
      calls = :counters.new(1, [])
      tasks = for _ <- 1..10, do: Theine.fetch_async(cache, :k, counted(calls, :loaded))

      assert Enum.all?(tasks, &is_pid(&1.pid))
      release_when_waiting(cache, :k, 9)

      assert Task.await_many(tasks, 5000) == List.duplicate({:ok, :loaded}, 10)
      assert :counters.get(calls, 1) == 1
      refute_received {:loading, _, _}
      assert Theine.get(cache, :k) == {:ok, :loaded}
      assert_loader_tables_empty(cache)
      assert_no_tasks(cache)
      # Each caller's lookup counts the miss once; the tasks look up nothing.
      assert %Stats{loads: 1, misses: 10} = Theine.stats(cache)
    end

    test "fetch_async tasks and fetch/4 callers share one load", %{cache: cache} do
      calls = :counters.new(1, [])
      loader = counted(calls, :loaded)
      pids = fetchers(cache, :k, loader, 5)
      tasks = for _ <- 1..5, do: Theine.fetch_async(cache, :k, loader)
      release_when_waiting(cache, :k, 9)

      assert Task.await_many(tasks, 5000) == List.duplicate({:ok, :loaded}, 5)
      assert collect(pids) |> Map.values() |> Enum.uniq() == [{:ok, :loaded}]
      assert :counters.get(calls, 1) == 1
      assert_loader_tables_empty(cache)
    end

    @tag :capture_log
    test "a loader crash surfaces through Task.yield as {:exit, _} and does not crash the caller",
         %{cache: cache} do
      # The tasks are not linked: the claimant's crash would otherwise take
      # this process down before the assertions below.
      tasks = for _ <- 1..5, do: Theine.fetch_async(cache, :k, gated(fn -> raise "boom" end))
      claimant = release_when_waiting(cache, :k, 4)

      outcomes = Map.new(tasks, &{&1.pid, Task.yield(&1, 5000)})

      assert {:exit, {%RuntimeError{message: "boom"}, [_ | _]}} = outcomes[claimant]

      for {pid, outcome} <- outcomes, pid != claimant do
        assert outcome == {:ok, {:error, {:load_failed, %RuntimeError{message: "boom"}}}}
      end

      assert Theine.get(cache, :k) == :error
      assert_loader_tables_empty(cache)
      assert_no_tasks(cache)
      assert %Stats{loads: 1, load_failures: 1} = Theine.stats(cache)

      # The key is not stuck.
      assert Theine.fetch_async(cache, :k, fn _ -> {:commit, 1} end) |> Task.await() == {:ok, 1}
    end

    @tag :capture_log
    test "a throw or an exit in the loader reaches Task.await as an exit of the caller only",
         %{cache: cache} do
      thrown = Theine.fetch_async(cache, :t, fn _ -> throw(:nope) end)
      assert {:exit, {{:nocatch, :nope}, [_ | _]}} = Task.yield(thrown, 5000)

      exited = Theine.fetch_async(cache, :e, fn _ -> exit(:gone) end)
      assert catch_exit(Task.await(exited, 5000)) == {:gone, {Task, :await, [exited, 5000]}}
      assert_loader_tables_empty(cache)
    end

    test "fetch_async on a hit returns an already-completed task", %{cache: cache} do
      :ok = Theine.put(cache, :k, :cached)
      sup = Config.get(cache).task_supervisor

      task = Theine.fetch_async(cache, :k, fn _ -> flunk("loader called on a hit") end)

      assert task.pid == nil
      assert Task.Supervisor.children(sup) == []
      assert Task.await(task, 0) == {:ok, :cached}
      assert %Stats{hits: 1, misses: 0, loads: 0} = Theine.stats(cache)
    end

    test "{:ignore, v} and {:commit, v, ttl: ms} complete the task as fetch/4 does",
         %{cache: cache} do
      assert Theine.fetch_async(cache, :a, fn _ -> {:ignore, :none} end) |> Task.await() ==
               {:ok, :none}

      assert Theine.get(cache, :a) == :error

      assert Theine.fetch_async(cache, :b, fn _ -> {:commit, 2, ttl: 60_000} end)
             |> Task.await() == {:ok, 2}

      assert {:ok, ttl} = Theine.ttl(cache, :b)
      assert is_integer(ttl) and ttl > 0 and ttl <= 60_000
    end

    test "the cache loader is used without a per-call loader, and a waiter's timeout: applies" do
      cache = unique_cache()
      test = self()

      loader = fn key ->
        send(test, {:loading, self(), key})

        receive do
          :go -> {:commit, key}
        end
      end

      start_supervised!({Theine, name: cache, max_size: :infinity, loader: loader})

      claimant = Theine.fetch_async(cache, :k)
      assert_receive {:loading, pid, :k}, 5000
      assert pid == claimant.pid

      waiter = Theine.fetch_async(cache, :k, nil, timeout: 10)
      assert Task.await(waiter, 5000) == {:error, :timeout}

      send(pid, :go)
      assert Task.await(claimant, 5000) == {:ok, :k}
      assert Theine.fetch_async(cache, :k) |> Task.await() == {:ok, :k}
      assert_loader_tables_empty(cache)
    end

    test "a missing loader or an invalid option raises ArgumentError in the caller",
         %{cache: cache} do
      sup = Config.get(cache).task_supervisor

      assert_raise ArgumentError, ~r/has no loader/, fn -> Theine.fetch_async(cache, :k) end

      assert_raise ArgumentError, ~r/timeout/, fn ->
        Theine.fetch_async(cache, :k, fn _ -> {:commit, 1} end, timeout: -1)
      end

      assert_raise ArgumentError, fn ->
        Theine.fetch_async(cache, :k, fn _ -> {:commit, 1} end, bogus: 1)
      end

      assert_raise ArgumentError, fn -> Theine.fetch_async(cache, :k, :not_a_fun) end
      assert Task.Supervisor.children(sup) == []
      assert %Stats{misses: 0} = Theine.stats(cache)
    end
  end

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
