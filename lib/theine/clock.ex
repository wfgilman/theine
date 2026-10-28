defmodule Theine.Clock do
  @moduledoc """
  The millisecond clock of the read and write paths (specs/06 §Clock).

  `now/1` is a macro, so the clock costs nothing to inject: in every
  environment but test it expands to `:erlang.monotonic_time(:millisecond)`,
  the BIF behind `System.monotonic_time/1` (specs/01 §Decisions), and the
  hot path in `Theine.get/2` stays a single BIF call with no module
  delegation. The test build sets

      config :theine, clock: Theine.Test.Clock

  and the same call sites expand to `Theine.Test.Clock.now(cache)`, which
  returns the test clock registered for that cache name, or the real clock
  when the test registered none. The choice is made once, at compile time,
  by `Application.compile_env/3`; changing it needs a recompile of this
  module and its callers.
  """

  @clock Application.compile_env(:theine, :clock, nil)

  @doc """
  The current time in monotonic milliseconds for `cache`. Expands inline;
  `cache` is evaluated only in the test build, where the clock is keyed by
  cache name.
  """
  if @clock do
    defmacro now(cache) do
      quote do: unquote(@clock).now(unquote(cache))
    end
  else
    defmacro now(_cache) do
      quote do: :erlang.monotonic_time(:millisecond)
    end
  end
end
