defmodule Theine.Test.Clock do
  @moduledoc """
  Agent-backed millisecond clock for tests (specs/06 §Clock).

  One clock per cache name. `now/1` returns the registered clock's time, or
  `System.monotonic_time(:millisecond)` when no clock is registered for that
  cache, so a test build with `config :theine, clock: Theine.Test.Clock` still
  runs on real time for every cache that does not opt in.

      start_supervised!({Theine.Test.Clock, cache: name})
      Theine.Test.Clock.advance(name, 10)
  """

  use Agent

  @type cache :: atom()

  @doc """
  Starts a clock for `opts[:cache]`, initially at `opts[:at]` (default: the
  real monotonic time, so test times look like production times).
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    cache = Keyword.fetch!(opts, :cache)
    at = Keyword.get_lazy(opts, :at, fn -> System.monotonic_time(:millisecond) end)
    Agent.start_link(fn -> at end, name: name(cache))
  end

  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :cache)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Current time in milliseconds for `cache`."
  @spec now(cache()) :: integer()
  def now(cache) when is_atom(cache) do
    case Process.whereis(name(cache)) do
      nil -> System.monotonic_time(:millisecond)
      pid -> Agent.get(pid, & &1)
    end
  end

  @doc "Moves the clock registered for `cache` forward by `ms` milliseconds."
  @spec advance(cache(), non_neg_integer()) :: integer()
  def advance(cache, ms) when is_atom(cache) and is_integer(ms) and ms >= 0 do
    Agent.get_and_update(name(cache), fn t -> {t + ms, t + ms} end)
  end

  defp name(cache), do: :"#{__MODULE__}.#{cache}"
end
