defmodule Theine.Test.LoaderHook do
  @moduledoc """
  Pause points between the steps of `Theine.Loader`'s single-flight
  algorithm (specs/07 §Decisions M4.2), compiled in only by the test build
  (`config :theine, loader_hook: Theine.Test.LoaderHook`).

  A fetching process arms one point with `pause_at/2` before it calls
  `Theine.fetch/4`. When it reaches that point it sends
  `{:paused, pid, point, key}` to the given process and blocks until
  `resume/1`; the point is disarmed as it fires. Processes that armed
  nothing pass through.

      spawn(fn ->
        LoaderHook.pause_at(:monitored, test)
        Theine.fetch(cache, :k, loader)
      end)

      assert_receive {:paused, pid, :monitored, :k}
      LoaderHook.resume(pid)

  The points, in algorithm order:

  - `:claim`: missed, about to `insert_new` the claim (step 1);
  - `:claim_lost`: the claim failed, about to look up the claimant (step 2);
  - `:monitored`: monitoring the claimant, the waiter row not yet inserted;
  - `:registered`: the waiter row inserted, the double-check not yet run
    (step 3);
  - `:timed_out`: the wait timed out, the row not yet deleted (step 4).

  Two more stop a refresh (specs/07 §Decisions M4.4b):

  - `:refresh_started`: the refresh's task has started, its pid not yet
    written into the `refreshing` row by the starter;
  - `:refresh_task`: the task itself, before it writes its own pid. A
    task cannot be armed before it exists, so this point is armed in the
    process that starts the refresh and fires in every task that process
    starts (found through `$callers`) until `disarm/1`.
  """

  @type point ::
          :claim
          | :claim_lost
          | :monitored
          | :registered
          | :timed_out
          | :refresh_started
          | :refresh_task

  @points [
    :claim,
    :claim_lost,
    :monitored,
    :registered,
    :timed_out,
    :refresh_started,
    :refresh_task
  ]

  @doc "Arms `point` in the calling process; `notify` receives `{:paused, …}`."
  @spec pause_at(point(), pid()) :: :ok
  def pause_at(point, notify) when point in @points and is_pid(notify) do
    Process.put({__MODULE__, point}, notify)
    :ok
  end

  @doc "Lets a process paused at a point continue."
  @spec resume(pid()) :: :ok
  def resume(pid) do
    send(pid, {__MODULE__, :resume})
    :ok
  end

  @doc "Disarms `point` in the calling process."
  @spec disarm(point()) :: :ok
  def disarm(point) when point in @points do
    Process.delete({__MODULE__, point})
    :ok
  end

  @doc false
  # Called by `Theine.Loader` at each point.
  @spec pause(point(), term()) :: :ok
  def pause(point, key) do
    case armed(point) do
      nil ->
        :ok

      notify ->
        send(notify, {:paused, self(), point, key})

        receive do
          {__MODULE__, :resume} -> :ok
        end
    end
  end

  # A refresh task reads the point from its starter's dictionary and leaves
  # it armed there; every other point is the process's own and fires once.
  defp armed(:refresh_task) do
    with [starter | _] <- Process.get(:"$callers"),
         {_, notify} when is_pid(notify) <-
           :erlang.process_info(starter, {:dictionary, {__MODULE__, :refresh_task}}) do
      notify
    else
      _ -> nil
    end
  end

  defp armed(point), do: Process.delete({__MODULE__, point})
end
