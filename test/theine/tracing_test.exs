defmodule Theine.TracingTest do
  @moduledoc """
  The hot-path budget (specs/01 §Acceptance): the exact multiset of calls
  into `:ets`, `:atomics`, `:counters` and `:persistent_term` that `get/2`
  makes. Policy-disabled multisets (specs/08 §Acceptance): with
  `max_size: :infinity` there is no read buffer, so no `:atomics` call.
  """

  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.Test.Trace

  @modules [:ets, :atomics, :counters, :persistent_term]

  setup do
    cache = unique_cache()
    start_supervised!({Theine, name: cache, max_size: :infinity})
    Theine.put(cache, :present, 1)
    %{cache: cache}
  end

  test "hit performs exactly persistent_term.get, ets.lookup, counters.add", %{cache: cache} do
    calls = Trace.calls(@modules, fn -> {:ok, 1} = Theine.get(cache, :present) end)

    assert calls == %{
             {:persistent_term, :get, 1} => 1,
             {:ets, :lookup, 2} => 1,
             {:counters, :add, 3} => 1
           }
  end

  test "miss performs exactly persistent_term.get, ets.lookup, counters.add", %{cache: cache} do
    calls = Trace.calls(@modules, fn -> :error = Theine.get(cache, :absent) end)

    assert calls == %{
             {:persistent_term, :get, 1} => 1,
             {:ets, :lookup, 2} => 1,
             {:counters, :add, 3} => 1
           }
  end

  test "get/3 adds nothing to the hit path", %{cache: cache} do
    calls = Trace.calls(@modules, fn -> 1 = Theine.get(cache, :present, 0) end)

    assert calls == %{
             {:persistent_term, :get, 1} => 1,
             {:ets, :lookup, 2} => 1,
             {:counters, :add, 3} => 1
           }
  end

  test "put performs persistent_term.get, atomics.add_get ×2, ets.insert", %{cache: cache} do
    calls = Trace.calls(@modules, fn -> :ok = Theine.put(cache, :new, 1) end)

    # One add_get for the id, one for `pending` (specs/01 §Write path, specs/03).
    assert calls == %{
             {:persistent_term, :get, 1} => 1,
             {:atomics, :add_get, 3} => 2,
             {:ets, :insert, 2} => 1
           }
  end
end
