defmodule Theine.WriteEventsTest do
  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.{Config, WriteEvents}

  test "deliver/2 counts the event in pending and sends it to the maintenance name" do
    name = :"write_events_test_#{System.unique_integer([:positive])}"
    Process.register(self(), name)

    config = %{
      Config.new!(name: :write_events_test, max_size: :infinity)
      | pending: :atomics.new(1, signed: true),
        maintenance: name
    }

    assert WriteEvents.deliver(config, {:put, :a, 1, 1, :infinity}) == :ok
    assert WriteEvents.deliver(config, {:removed, :a, 1}) == :ok

    assert :atomics.get(config.pending, 1) == 2
    assert_received {:put, :a, 1, 1, :infinity}
    assert_received {:removed, :a, 1}
  end

  test "events from many writers all reach the maintenance process in put order per key" do
    cache = unique_cache()
    start_supervised!({Theine, name: cache, max_size: :infinity})

    1..4
    |> Enum.map(fn w ->
      Task.async(fn -> for i <- 1..500, do: Theine.put(cache, {w, rem(i, 50)}, i) end)
    end)
    |> Task.await_many()

    assert_eventually(fn -> Theine.Maintenance.info(cache).pending == 0 end)
    assert Theine.size(cache) == 200

    # The policy's id for each key is the id of the tuple in the table: each
    # writer sends its own key's events in order.
    for w <- 1..4, i <- 0..49 do
      [{_, _, id, _, _, _}] = :ets.lookup(cache, {w, i})
      assert {:ok, {_, ^id, _, _, _, _}} = Theine.Maintenance.policy_row(cache, {w, i})
    end
  end
end
