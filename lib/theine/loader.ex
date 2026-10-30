defmodule Theine.Loader do
  @moduledoc """
  Single-flight loading (specs/07 §Single-flight): on a miss, one process
  per key, the **claimant**, runs the loader; every other process that
  misses the same key meanwhile, a **waiter**, receives the claimant's
  result instead of loading again.

  Coordination goes through two public tables created by `Theine.Owner`,
  both empty whenever no load is in progress:

      inflight  :set            {key, claimant_pid, ref}
      waiters   :duplicate_bag  {{key, ref}, waiter_pid, monitor}

  A miss claims the key with `:ets.insert_new/2`. A process that loses the
  claim monitors the claimant, registers a waiter row, checks that the
  claim it saw is still in place and waits for `{:theine_loaded, monitor,
  result}`. The claimant runs the loader in its own process, stores the
  value on `:commit`, then releases the claim *before* it reads the waiter
  rows, so a waiter that still sees the claim after registering is
  certain to be notified, and one that does not falls through to a retry.
  A process that wins the claim looks the key up once more before it
  loads, because the previous claimant may have committed and released
  between this process's miss and its claim.

  The monitor is an alias monitor (`alias: :demonitor`) and the claimant
  sends to the alias, so a waiter that gave up (timeout) and demonitored
  never receives a late notification (specs/07 §Decisions M4.1).

  A dead claimant leaves its claim behind (its `after` never ran). The
  first waiter to see the `:DOWN` deletes it by exact object, and a
  `:DOWN` with `:noproc` (the claimant was gone before the monitor) or
  `:normal` sends the waiter back to claim, so a killed claimant never
  blocks the key (specs/07 §Decisions M4.1).

  `fetch_async/4` runs the same algorithm in a task under the cache's
  `Task.Supervisor`, so the task is the claimant or a waiter.

  Refreshes (specs/07 §Refresh-after-write) do not go through the claim. A
  reader whose hit is at least `refresh_after_write` old, or a call to
  `refresh/2`, claims the key in a third table, `refreshing` (`{key, ref,
  task_pid}`), with `:ets.insert_new/2`, and starts a task under the same
  supervisor that loads and stores the value and then deletes the row. The
  reader returns the stale value at once; a reader that loses the
  `insert_new` returns it too, so one refresh runs per key at a time. The
  exception is a row whose task is dead: a task killed from outside never
  deletes its row, so the losing reader deletes it and claims again.

  The loader is never called from the maintenance process. Each call is
  wrapped in `[:theine, :load, :start | :stop | :exception]` telemetry with
  `%{cache: name}` metadata (the key is omitted) and counted in the
  `loads` and `load_failures` counters.
  """

  alias Theine.{Config, Entry, Stats}

  require Logger

  @type key :: Entry.key()
  @type value :: Entry.value()

  @typedoc """
  What a loader returns: `{:commit, value}` stores `value` with the
  cache's default TTL, `{:commit, value, opts}` stores it with the options
  of `Theine.put/4` (`ttl:`, `weight:`), and `{:ignore, value}` returns it
  without storing anything.
  """
  @type result :: {:commit, value()} | {:commit, value(), keyword()} | {:ignore, value()}

  @type loader :: (key() -> result())

  @typedoc """
  Why a waiter did not get a value: the claimant's loader raised (the
  exception struct), threw (`{:nocatch, value}`) or exited (the exit
  reason), or the claimant died before notifying (the monitor's reason,
  e.g. `:killed`); or the wait took longer than `timeout:`.
  """
  @type error :: {:load_failed, term()} | :timeout

  @loads Stats.loads()
  @load_failures Stats.load_failures()
  @refreshes Stats.refreshes()

  # Claims tried after the first before loading without coalescing
  # (specs/07 §Single-flight step 6).
  @max_attempts 3

  @default_timeout 5000

  # The test build pauses a fetcher between the steps of the algorithm, so
  # that tests can interleave a claimant and a waiter deterministically
  # (specs/07 §Decisions M4.2). `config/test.exs` sets
  # `loader_hook: Theine.Test.LoaderHook`; every other build compiles
  # `pause/2` to `:ok`, as `Theine.Clock` compiles to the BIF.
  @hook Application.compile_env(:theine, :loader_hook, nil)

  if @hook do
    defmacrop pause(point, key) do
      quote do: unquote(@hook).pause(unquote(point), unquote(key))
    end
  else
    defmacrop pause(_point, _key), do: :ok
  end

  @doc """
  `Theine.fetch/4`: the value of `key`, loaded with `loader` (or the
  cache's `loader:` when `loader` is nil) on a miss, with exactly one load
  per key at a time.

  Raises `ArgumentError` when neither loader is given, or for an invalid
  `timeout:`.
  """
  @spec fetch(Config.cache(), key(), loader() | nil, keyword()) ::
          {:ok, value()} | {:error, error()}
  def fetch(cache, key, loader, opts) when is_list(opts) do
    config = :persistent_term.get(cache)
    loader = resolve!(config, loader)
    timeout = timeout!(opts)

    case lookup(config, key, loader) do
      {:ok, _} = hit -> hit
      :error -> claim_or_wait(config, key, loader, timeout, 0)
    end
  end

  @doc """
  `Theine.fetch_async/4`: `fetch/4` in a task under the cache's
  `Task.Supervisor`, unlinked from the caller (specs/07 §Asynchronous).

  The loader and the options are checked in the caller, so an
  `ArgumentError` raises there rather than in the task. A hit returns an
  already-completed task and spawns nothing. On a miss the task goes
  straight to the claim: the caller's lookup has already counted the miss,
  and a value committed since is found by the claimant's recheck or by
  waiting on the claim, as in `fetch/4` (specs/07 §Decisions M4.3).
  """
  @spec fetch_async(Config.cache(), key(), loader() | nil, keyword()) :: Task.t()
  def fetch_async(cache, key, loader, opts) when is_list(opts) do
    config = :persistent_term.get(cache)
    loader = resolve!(config, loader)
    timeout = timeout!(opts)

    case lookup(config, key, loader) do
      {:ok, _} = hit ->
        Task.completed(hit)

      :error ->
        Task.Supervisor.async_nolink(config.task_supervisor, fn ->
          claim_or_wait(config, key, loader, timeout, 0)
        end)
    end
  end

  @doc """
  `Theine.refresh/2`: start a background refresh of `key` with the cache's
  `loader:`, whatever its age (specs/07 §Refresh-after-write). Returns
  `{:error, :refreshing}` when one is running for `key` and `{:error,
  :no_loader}` without a cache loader.
  """
  @spec refresh(Config.cache(), key()) :: :ok | {:error, :refreshing | :no_loader}
  def refresh(cache, key) do
    case :persistent_term.get(cache) do
      %Config{loader: nil} -> {:error, :no_loader}
      %Config{loader: loader} = config -> start_refresh(config, key, loader)
    end
  end

  @doc false
  # A stale hit in `Theine.get/2` or `fetch/4` (specs/07 §Refresh-after-
  # write): start a refresh unless one is running. The reader must not fail
  # for it: a task supervisor that is restarting (an exit from
  # `start_child`) leaves the next stale hit to try again.
  @spec refresh_stale(Config.t(), key(), loader()) :: :ok
  def refresh_stale(config, key, loader) do
    _ = start_refresh(config, key, loader)
    :ok
  catch
    :exit, _ -> :ok
  end

  # Steps 1 and 2: claim the key's refresh with `insert_new`, then start the
  # task, which deletes exactly its row when it is done. The row is `{key,
  # ref, pid}`, with the task's pid once it is known (nil before), so that a
  # task killed from outside, whose `after` never runs, leaves a row that a
  # later claim can tell is dead (specs/07 §Decisions M4.4b).
  defp start_refresh(%Config{refreshing: refreshing} = config, key, loader) do
    ref = make_ref()

    if :ets.insert_new(refreshing, {key, ref, nil}),
      do: start_task(config, key, loader, ref),
      else: reclaim(config, key, loader, ref)
  end

  # The claim failed. A row naming a dead task is deleted by exact object
  # and the key claimed once more; a row whose task is alive, or not known
  # yet, or no row at all (the refresh just finished) means `:refreshing`.
  defp reclaim(%Config{refreshing: refreshing} = config, key, loader, ref) do
    with [{_, _, pid} = row] when is_pid(pid) <- :ets.lookup(refreshing, key),
         false <- Process.alive?(pid),
         true <- :ets.delete_object(refreshing, row),
         true <- :ets.insert_new(refreshing, {key, ref, nil}) do
      start_task(config, key, loader, ref)
    else
      _ -> {:error, :refreshing}
    end
  end

  # A task that could not be started gives the claim back. One that was
  # started gets its pid written into the row, unless the task already did
  # that itself.
  defp start_task(%Config{refreshing: refreshing} = config, key, loader, ref) do
    Task.Supervisor.start_child(config.task_supervisor, fn ->
      refresh_task(config, key, loader, ref)
    end)
  catch
    kind, reason ->
      true = :ets.delete_object(refreshing, {key, ref, nil})
      :erlang.raise(kind, reason, __STACKTRACE__)
  else
    {:ok, pid} ->
      pause(:refresh_started, key)
      record_task(refreshing, key, ref, pid)
      :counters.add(config.counters, @refreshes, 1)
      :ok
  end

  # The starter's write of the task's pid, as a compare-and-swap on the
  # unique ref: by now the task may have finished and deleted its row, and
  # the key may hold a newer claim, which `update_element/3` would mark
  # with this task's (dead) pid. Wildcard atoms or a map in `key` only widen
  # the head's match (a scan of the running refreshes instead of a lookup);
  # the ref still picks this one row. The new row's key is taken from the
  # matched object, because `select_replace/2` rejects a `:const` key it
  # cannot prove unchanged, which is any key the head does not fully bind.
  defp record_task(refreshing, key, ref, pid) do
    new = {{{:element, 1, :"$_"}, {:const, ref}, {:const, pid}}}
    _ = :ets.select_replace(refreshing, [{{key, ref, nil}, [], [new]}])
    :ok
  end

  # The refresh task: one load as a claimant's (telemetry, the `loads` and
  # `load_failures` counters, the value stored on `:commit` even if the key
  # was deleted meanwhile). On `{:ignore, v}` or a failure the old value
  # stays. A failure is logged without the key, which may be sensitive, and
  # without the stacktrace, whose top frame can carry the loader's
  # arguments; the telemetry event carries both kind and stacktrace for a
  # handler that wants them.
  #
  # The task writes its own pid first, in case its starter died before
  # doing so. The row is this task's: only the task deletes it, and a claim
  # deletes only a row naming a dead pid.
  defp refresh_task(%Config{name: name, refreshing: refreshing} = config, key, loader, ref) do
    pause(:refresh_task, key)
    true = :ets.update_element(refreshing, key, {3, self()})
    _ = run(config, key, loader)
    :ok
  catch
    kind, reason ->
      stack = __STACKTRACE__

      Logger.warning(
        "Theine cache #{inspect(name)} kept a stale value: its refresh failed with " <>
          Exception.format_banner(kind, reason, stack)
      )

      :telemetry.execute(
        [:theine, :refresh, :exception],
        %{system_time: System.system_time()},
        %{cache: name, kind: kind, reason: reason, stacktrace: stack}
      )

      :ok
  after
    true = :ets.delete_object(refreshing, {key, ref, self()})
  end

  # The lookup of `fetch/4` and `fetch_async/4`: `get/2`, unless a stale
  # hit must be refreshed with this call's loader rather than the cache's.
  defp lookup(%Config{refresh_after_write: :infinity, name: cache}, key, _loader),
    do: Theine.get(cache, key)

  defp lookup(%Config{name: cache}, key, loader), do: Theine.refreshing_get(cache, key, loader)

  defp resolve!(_config, loader) when is_function(loader, 1), do: loader
  defp resolve!(%Config{loader: loader}, nil) when is_function(loader, 1), do: loader

  defp resolve!(%Config{name: name}, nil) do
    raise ArgumentError,
          "cache #{inspect(name)} has no loader: pass one to Theine.fetch/4 " <>
            "or start the cache with the :loader option"
  end

  defp resolve!(_config, other) do
    raise ArgumentError, "expected a loader of arity 1 or nil, got: #{inspect(other)}"
  end

  defp timeout!(opts) do
    case Keyword.validate!(opts, timeout: @default_timeout) |> Keyword.fetch!(:timeout) do
      :infinity ->
        :infinity

      ms when is_integer(ms) and ms >= 0 ->
        ms

      other ->
        raise ArgumentError,
              "option :timeout must be a non-negative number of milliseconds or :infinity, " <>
                "got: #{inspect(other)}"
    end
  end

  # Step 1: claim, else wait on the current claimant (step 2), or retry when
  # it finished between the two lookups.
  defp claim_or_wait(%Config{inflight: inflight} = config, key, loader, timeout, attempts) do
    ref = make_ref()
    pause(:claim, key)

    if :ets.insert_new(inflight, {key, self(), ref}) do
      claim(config, key, loader, ref)
    else
      pause(:claim_lost, key)

      case :ets.lookup(inflight, key) do
        [{_, pid, claim_ref}] -> wait(config, key, loader, timeout, attempts, pid, claim_ref)
        [] -> retry(config, key, loader, timeout, attempts)
      end
    end
  end

  # Steps 2 and 3: register as a waiter on the claim `{key, pid, ref}`,
  # then check that the claim is still there. If it is not, the claimant
  # released it before this row could be seen, so no notification is
  # owed; one may still have been sent if the claimant read the rows after
  # the insert, and it is the answer.
  defp wait(config, key, loader, timeout, attempts, pid, ref) do
    %Config{inflight: inflight, waiters: waiters} = config
    mon = :erlang.monitor(:process, pid, alias: :demonitor)
    pause(:monitored, key)
    row = {{key, ref}, self(), mon}
    true = :ets.insert(waiters, row)
    pause(:registered, key)

    case :ets.lookup(inflight, key) do
      [{_, ^pid, ^ref}] ->
        await(config, key, loader, timeout, attempts, {pid, ref, mon, row})

      _ ->
        true = :ets.delete_object(waiters, row)
        Process.demonitor(mon, [:flush])

        receive do
          {:theine_loaded, ^mon, result} -> result
        after
          0 -> retry(config, key, loader, timeout, attempts)
        end
    end
  end

  # Step 4.
  defp await(config, key, loader, timeout, attempts, {pid, ref, mon, row}) do
    %Config{inflight: inflight, waiters: waiters} = config

    receive do
      {:theine_loaded, ^mon, result} ->
        # The claimant deletes the waiter rows of its claim.
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, _, reason} ->
        true = :ets.delete_object(waiters, row)
        # The claimant died holding the claim; drop it so the key can be
        # claimed again. By exact object: a new claim is left alone.
        true = :ets.delete_object(inflight, {key, pid, ref})

        case Theine.get(config.name, key) do
          {:ok, _} = hit ->
            hit

          :error when reason in [:normal, :noproc] ->
            retry(config, key, loader, timeout, attempts)

          :error ->
            {:error, {:load_failed, reason}}
        end
    after
      timeout ->
        pause(:timed_out, key)
        true = :ets.delete_object(waiters, row)
        # Deactivates the alias: a notification sent from now on is dropped.
        Process.demonitor(mon, [:flush])

        receive do
          {:theine_loaded, ^mon, result} -> result
        after
          0 -> {:error, :timeout}
        end
    end
  end

  # Step 6: the claimant finished without this process hearing from it.
  defp retry(config, key, loader, timeout, attempts) do
    case Theine.get(config.name, key) do
      {:ok, _} = hit ->
        hit

      :error when attempts < @max_attempts ->
        claim_or_wait(config, key, loader, timeout, attempts + 1)

      :error ->
        # Give up on coalescing rather than spin.
        run(config, key, loader)
    end
  end

  # Load, as the claimant: release the claim, then notify the waiters
  # registered on it, whatever the loader did. A failure is re-raised here
  # with its original kind and stacktrace, as from any function call.
  #
  # The claim is checked against the table first: a claimant that finished
  # between this process's miss and its `insert_new` has committed and
  # released, and loading again would break exactly-once (specs/07
  # §Decisions M4.2).
  defp claim(config, key, loader, ref) do
    case Entry.peek(config, key) do
      {:ok, _} = hit -> hit
      :error -> run(config, key, loader)
    end
  catch
    kind, reason ->
      stack = __STACKTRACE__
      release(config, key, ref, {:error, {:load_failed, failure_reason(kind, reason, stack)}})
      :erlang.raise(kind, reason, stack)
  else
    reply ->
      release(config, key, ref, reply)
      reply
  end

  # The order is load-bearing (specs/07 §Single-flight): the claim goes
  # first, then the waiter rows are read.
  defp release(%Config{inflight: inflight, waiters: waiters}, key, ref, reply) do
    true = :ets.delete_object(inflight, {key, self(), ref})

    for {_, _pid, mon} <- :ets.lookup(waiters, {key, ref}) do
      send(mon, {:theine_loaded, mon, reply})
    end

    true = :ets.delete(waiters, {key, ref})
    :ok
  end

  defp failure_reason(:error, reason, stack), do: Exception.normalize(:error, reason, stack)
  defp failure_reason(:throw, value, _stack), do: {:nocatch, value}
  defp failure_reason(:exit, reason, _stack), do: reason

  # One loader call: telemetry around it, the result stored, the counters
  # bumped. `loads` counts every completed call, `load_failures` the ones
  # that raised, threw or exited (as Caffeine's loadCount and
  # loadFailureCount).
  defp run(%Config{name: name, counters: counters} = config, key, loader) do
    metadata = %{cache: name}

    :telemetry.span([:theine, :load], metadata, fn ->
      {commit(config, key, loader.(key)), metadata}
    end)
  catch
    kind, reason ->
      :counters.add(counters, @loads, 1)
      :counters.add(counters, @load_failures, 1)
      :erlang.raise(kind, reason, __STACKTRACE__)
  else
    reply ->
      :counters.add(counters, @loads, 1)
      reply
  end

  defp commit(config, key, {:commit, value}) do
    :ok = Entry.put(config, key, value, [])
    {:ok, value}
  end

  defp commit(config, key, {:commit, value, opts}) when is_list(opts) do
    :ok = Entry.put(config, key, value, opts)
    {:ok, value}
  end

  defp commit(_config, _key, {:ignore, value}), do: {:ok, value}

  defp commit(%Config{name: name}, _key, other) do
    raise ArgumentError,
          "the loader of cache #{inspect(name)} must return {:commit, value}, " <>
            "{:commit, value, opts} or {:ignore, value}, got: #{inspect(other, limit: 5)}"
  end
end
