defmodule Theine.Test.TraceTest do
  use ExUnit.Case, async: true

  alias Theine.Test.Trace

  test "returns the multiset of :ets calls made by the function" do
    table = :ets.new(:trace_test, [:public])
    :ets.insert(table, {:k, 1})

    calls =
      Trace.calls([:ets, :persistent_term], fn ->
        [{:k, 1}] = :ets.lookup(table, :k)
        [] = :ets.lookup(table, :missing)
        true = :ets.insert(table, {:j, 2})
        nil = :persistent_term.get({__MODULE__, :absent}, nil)
        # Not in the traced module list, so not reported.
        _ = :atomics.new(1, [])
      end)

    assert calls == %{
             {:ets, :lookup, 2} => 2,
             {:ets, :insert, 2} => 1,
             {:persistent_term, :get, 2} => 1
           }
  end

  test "a function making no traced calls returns an empty multiset" do
    assert Trace.calls([:ets], fn -> :ok end) == %{}
  end

  test "an exception in the traced function is re-raised in the caller" do
    assert_raise RuntimeError, "boom", fn ->
      Trace.calls([:ets], fn -> raise "boom" end)
    end
  end
end
