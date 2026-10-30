defmodule Theine.Stress.WriteEventsTest do
  # Saturates every scheduler, so it runs alone.
  use ExUnit.Case, async: false

  import Theine.Test.Helpers

  alias Theine.{Config, Maintenance}

  @moduletag :stress
  @moduletag timeout: 300_000

  @puts 1_000_000
  @keys 100_000

  # One writer pinned to each scheduler, `div(@puts, writers)` puts each on
  # keys drawn from one shared space, so writers race on the same keys
  # (discovered issue 2), with a delete after every eighth put.
  defp write_from_every_scheduler(cache) do
    writers = System.schedulers_online()
    per_writer = div(@puts, writers)
    test = self()

    for s <- 1..writers do
      spawn_on_scheduler(s, fn ->
        :rand.seed(:exsss, {s, 1, 2})

        for i <- 1..per_writer do
          key = :rand.uniform(@keys)
          :ok = Theine.put(cache, key, {s, i})
          if rem(i, 8) == 0, do: :ok = Theine.delete(cache, :rand.uniform(@keys))
        end

        send(test, {:writer_done, s})
      end)
    end

    for s <- 1..writers, do: assert_receive({:writer_done, ^s}, 240_000)
    writers * per_writer
  end

  for max_size <- [:infinity, 50_000] do
    @tag max_size: max_size
    test "1_000_000 puts across all schedulers end with policy count equal to table size (max_size #{max_size})",
         %{max_size: max_size} do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: max_size})
      config = Config.get(cache)

      assert write_from_every_scheduler(cache) >= @puts - System.schedulers_online()

      # No restart, so every counted event is consumed exactly once.
      assert_eventually(fn -> :atomics.get(config.pending, 1) == 0 end, 30_000)
      info = Maintenance.info(cache)
      assert info.pending == 0

      table = :ets.tab2list(cache)
      assert info.size == length(table)
      assert info.weighted_size == info.size
      assert Theine.size(cache) == info.size
      if max_size != :infinity, do: assert(info.size <= max_size)

      # Every key the table holds has its policy row under the table's id;
      # with the counts equal, the policy holds no other row.
      for {key, _value, id, _weight, _written_at, _expires_at} <- table do
        assert {:ok, {^key, ^id, _, _, 1, :infinity}} = Maintenance.policy_row(cache, key)
      end
    end
  end
end
