defmodule Theine.Test.HelpersTest do
  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  test "spawn_on_scheduler runs on the requested scheduler id" do
    parent = self()

    for n <- 1..:erlang.system_info(:schedulers_online) do
      spawn_on_scheduler(n, fn -> send(parent, {n, :erlang.system_info(:scheduler_id)}) end)
      assert_receive {^n, ^n}
    end
  end

  test "spawn_on_scheduler rejects a scheduler id out of range" do
    assert_raise ArgumentError, fn -> spawn_on_scheduler(0, fn -> :ok end) end
  end

  test "assert_eventually returns the first truthy value of a background condition" do
    counter = :counters.new(1, [])
    spawn_link(fn -> for _ <- 1..3, do: :counters.add(counter, 1, 1) end)

    assert assert_eventually(fn -> :counters.get(counter, 1) == 3 && :done end) == :done
  end

  test "assert_eventually retries assertion errors and re-raises the last one on timeout" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_eventually(fn -> assert 1 == 2 end, 20)
      end

    assert error.expr != nil
  end

  test "assert_eventually flunks when the condition stays falsy" do
    assert_raise ExUnit.AssertionError, ~r/within 20 ms/, fn ->
      assert_eventually(fn -> false end, 20)
    end
  end
end
