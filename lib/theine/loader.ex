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

  The loader is never called from the maintenance process. Each call is
  wrapped in `[:theine, :load, :start | :stop | :exception]` telemetry with
  `%{cache: name}` metadata (the key is omitted) and counted in the
  `loads` and `load_failures` counters.
  """

  alias Theine.{Config, Entry, Stats}

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

    case Theine.get(cache, key) do
      {:ok, _} = hit -> hit
      :error -> claim_or_wait(config, key, loader, timeout, 0)
    end
  end

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
