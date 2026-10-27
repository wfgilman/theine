defmodule Theine.Test.ClockTest do
  use ExUnit.Case, async: true

  alias Theine.Test.Clock

  setup do
    %{cache: :"cache_#{System.unique_integer([:positive])}"}
  end

  test "advance/1 moves now/1 forward without sleeping", %{cache: cache} do
    start_supervised!({Clock, cache: cache, at: 1_000})

    assert Clock.now(cache) == 1_000
    assert Clock.advance(cache, 10) == 1_010
    assert Clock.now(cache) == 1_010
    assert Clock.advance(cache, 0) == 1_010
  end

  test "now/1 falls back to the real monotonic clock when no clock is registered",
       %{cache: cache} do
    before = System.monotonic_time(:millisecond)
    now = Clock.now(cache)
    assert before <= now and now <= System.monotonic_time(:millisecond)
  end

  test "clocks for different caches are independent", %{cache: cache} do
    other = :"#{cache}_other"
    start_supervised!({Clock, cache: cache, at: 0})
    start_supervised!({Clock, cache: other, at: 0})

    Clock.advance(cache, 50)
    assert Clock.now(cache) == 50
    assert Clock.now(other) == 0
  end
end
