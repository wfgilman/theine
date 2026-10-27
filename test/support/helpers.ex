defmodule Theine.Test.Helpers do
  @moduledoc """
  Shared test helpers (specs/10 §Required helpers). `import Theine.Test.Helpers`.
  """

  @poll_ms 5

  @doc """
  Polls `fun` until it returns a truthy value or stops raising
  `ExUnit.AssertionError`, and returns that value. After `timeout` ms the
  last assertion error is re-raised, or the test is flunked if `fun` only
  returned falsy values.

  This is the only sanctioned way to wait for a background process
  (specs/10 §Tiers); it is not a retry for flaky assertions.
  """
  @spec assert_eventually((-> term()), non_neg_integer()) :: term()
  def assert_eventually(fun, timeout \\ 1000) when is_function(fun, 0) do
    poll(fun, System.monotonic_time(:millisecond) + timeout, timeout)
  end

  defp poll(fun, deadline, timeout) do
    outcome =
      try do
        fun.()
      rescue
        e in ExUnit.AssertionError -> {:__assertion__, e, __STACKTRACE__}
      end

    case outcome do
      {:__assertion__, e, stack} ->
        if past?(deadline), do: reraise(e, stack), else: retry(fun, deadline, timeout)

      falsy when falsy in [nil, false] ->
        if past?(deadline),
          do: ExUnit.Assertions.flunk("condition not met within #{timeout} ms"),
          else: retry(fun, deadline, timeout)

      value ->
        value
    end
  end

  defp past?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp retry(fun, deadline, timeout) do
    Process.sleep(@poll_ms)
    poll(fun, deadline, timeout)
  end

  @doc """
  Spawns a linked process bound to scheduler `n` (1-based, as reported by
  `:erlang.system_info(:scheduler_id)`) and returns its pid.
  """
  @spec spawn_on_scheduler(pos_integer(), (-> term())) :: pid()
  # OTP 28's spawn_opt/2 spec omits the {:scheduler, n} option the runtime
  # accepts, so dialyzer concludes the call can never return.
  @dialyzer {:nowarn_function, spawn_on_scheduler: 2}
  def spawn_on_scheduler(n, fun) when is_integer(n) and is_function(fun, 0) do
    schedulers = :erlang.system_info(:schedulers_online)

    unless n in 1..schedulers//1 do
      raise ArgumentError, "scheduler #{n} is not in 1..#{schedulers}"
    end

    :erlang.spawn_opt(fun, [:link, {:scheduler, n}])
  end
end
