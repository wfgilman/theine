defmodule Theine.SupervisorTest do
  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.{Config, Maintenance}

  # A long interval keeps the timer out of the pass counts asserted below.
  @quiet [maintenance_interval: 60_000]

  defp children(sup) do
    for {id, pid, _type, _modules} <- Supervisor.which_children(sup), into: %{}, do: {id, pid}
  end

  defp start_cache(opts) do
    cache = unique_cache()
    sup = start_supervised!({Theine, [name: cache] ++ opts ++ @quiet})
    {cache, sup}
  end

  describe "one partition (specs/08 §Supervision tree)" do
    test "keeps the three-child tree with Maintenance under its own name" do
      {cache, sup} = start_cache(max_size: :infinity)

      assert %{Theine.Owner => _, Theine.TaskSupervisor => _, Theine.Maintenance => pid} =
               children(sup)

      assert map_size(children(sup)) == 3
      assert Process.whereis(Maintenance.name(cache)) == pid
      assert Process.whereis(Theine.Partitions.name(cache)) == nil
    end
  end

  describe "partitions: 4 (specs/12 §Supervision)" do
    @n 4

    setup do
      {cache, sup} = start_cache(max_size: :infinity, partitions: @n)
      partitions = children(sup)[Theine.Partitions]
      %{cache: cache, sup: sup, partitions: partitions}
    end

    test "the last child supervises one Maintenance per partition under its partition's name",
         %{cache: cache, sup: sup, partitions: partitions} do
      assert Map.keys(children(sup)) |> Enum.sort() ==
               Enum.sort([Theine.Owner, Theine.TaskSupervisor, Theine.Partitions])

      assert Process.whereis(Theine.Partitions.name(cache)) == partitions
      assert Process.whereis(Maintenance.name(cache)) == children(partitions)[{Maintenance, 0}]

      for p <- 0..(@n - 1) do
        pid = children(partitions)[{Maintenance, p}]
        assert is_pid(pid)
        assert Process.whereis(Maintenance.name(cache, p)) == pid
        assert Process.whereis(elem(Config.get(cache).maintenances, p)) == pid
      end

      assert map_size(children(partitions)) == @n
    end

    test "killing partition 1 restarts only partition 1", %{
      cache: cache,
      sup: sup,
      partitions: partitions
    } do
      before = children(sup)
      before_partitions = children(partitions)

      # Distinct pass counts per partition, so a restart of any of them
      # would show as a count back at 0.
      for p <- 0..(@n - 1), _ <- 0..p, do: :ok = Maintenance.run(cache, p)
      passes = for p <- 0..(@n - 1), into: %{}, do: {p, Maintenance.info(cache, p).passes}
      assert passes == %{0 => 1, 1 => 2, 2 => 3, 3 => 4}

      old = before_partitions[{Maintenance, 1}]
      Process.exit(old, :kill)

      assert_eventually(fn ->
        Process.whereis(Maintenance.name(cache, 1)) not in [nil, old]
      end)

      restarted = Process.whereis(Maintenance.name(cache, 1))

      assert children(sup) == before
      assert children(partitions) == %{before_partitions | {Maintenance, 1} => restarted}
      assert Maintenance.info(cache, 1).passes == 0

      for p <- [0, 2, 3] do
        assert Maintenance.info(cache, p).passes == passes[p]
      end
    end

    test "killing Owner restarts every partition", %{
      cache: cache,
      sup: sup,
      partitions: partitions
    } do
      before = children(partitions)
      Process.exit(children(sup)[Theine.Owner], :kill)

      assert_eventually(fn ->
        new = Process.whereis(Theine.Partitions.name(cache))
        is_pid(new) and new != partitions
      end)

      restarted = children(Process.whereis(Theine.Partitions.name(cache)))

      for p <- 0..(@n - 1) do
        assert is_pid(restarted[{Maintenance, p}])
        assert restarted[{Maintenance, p}] != before[{Maintenance, p}]
      end

      Theine.put(cache, :k, :v)
      assert Theine.get(cache, :k) == {:ok, :v}
    end

    test "stopping the cache unregisters every partition", %{cache: cache} do
      :ok = stop_supervised!({Theine, cache})

      for p <- 0..(@n - 1) do
        assert Process.whereis(Maintenance.name(cache, p)) == nil
      end

      assert Process.whereis(Theine.Partitions.name(cache)) == nil
      assert :persistent_term.get(Config.key(cache), :gone) == :gone
    end
  end
end
