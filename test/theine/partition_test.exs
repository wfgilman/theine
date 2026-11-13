defmodule Theine.PartitionTest do
  @moduledoc """
  Routing by partition (specs/12 §The partition of a key, §Ids carry the
  partition; IMPLEMENTATION_PLAN.md M8.1) and capacity shares (§Each
  partition is a whole policy, M8.4). The partitioned paths are driven
  through a config built by hand: `Theine.Entry` writes into a private table, and the
  partitions' maintenance names are held by forwarders owned by the test.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  import Theine.Test.Helpers

  alias Theine.{Config, Entry, Partition, WriteEvents}
  alias Theine.Test.Trace

  doctest Partition

  @ns [1, 2, 4, 8]

  # A config of `n` partitions over a fresh private entries table, with no
  # process behind its maintenance names unless the test registers one:
  # `WriteEvents.deliver/2` then drops the event, as during a restart.
  defp partitioned_config(n, opts \\ []) do
    cache = unique_cache()

    %{
      Config.new!([name: cache, max_size: :infinity] ++ opts)
      | partitions: n,
        maintenances: Config.maintenance_names(cache, n),
        table: :ets.new(:entries, [:set, :public]),
        ids: :atomics.new(n, signed: false),
        pending: :atomics.new(n, signed: true),
        counters: :counters.new(Theine.Stats.field_count(), [:write_concurrency])
    }
  end

  # Registers one process per partition under that partition's name; each
  # forwards what it receives to the test, tagged with its partition.
  defp register_forwarders(%Config{maintenances: names}) do
    test = self()

    for {name, p} <- names |> Tuple.to_list() |> Enum.with_index() do
      pid =
        spawn_link(fn ->
          Process.register(self(), name)
          send(test, {:registered, p})
          forward(test, p)
        end)

      assert_receive {:registered, ^p}
      pid
    end
  end

  defp forward(test, p) do
    receive do
      message ->
        send(test, {:partition, p, message})
        forward(test, p)
    end
  end

  defp entry_id(%Config{table: table}, key), do: :ets.lookup_element(table, key, 3)

  describe "of_key/2 and of_id/2" do
    property "of_key is the top log2(n) bits of the key's 32-bit phash2" do
      check all key <- term(), n <- member_of(@ns) do
        h = :erlang.phash2(key, 4_294_967_296)
        bits = n |> Integer.digits(2) |> length() |> Kernel.-(1)
        p = Partition.of_key(key, n)

        assert p in 0..(n - 1)
        assert p == if(n == 1, do: 0, else: h >>> (32 - bits))
      end
    end

    test "of_key spreads keys over every partition" do
      for n <- [2, 4, 8] do
        counts = Enum.frequencies(for i <- 1..8_000, do: Partition.of_key({:key, i}, n))
        assert map_size(counts) == n
        assert Enum.all?(Map.values(counts), &(&1 > div(8_000 * 8, n * 10)))
      end
    end
  end

  describe "shares (specs/12 §Each partition is a whole policy)" do
    property "oversized?/4 is a weight above the share of the key's partition" do
      check all key <- term(),
                n <- member_of(@ns),
                max_size <- integer(1..200_000),
                weight <- integer(1..(div(max_size, n) + 3)) do
        share = Partition.share(max_size, n, Partition.of_key(key, n))
        assert Partition.oversized?(weight, max_size, n, key) == weight > share
      end
    end

    test "a weight of exactly the larger share is the only one that hashes the key" do
      # 40_002 over 4: shares 10_001, 10_001, 10_000, 10_000.
      for weight <- [1, 10_000, 10_002] do
        calls = Trace.calls([:erlang], fn -> Partition.oversized?(weight, 40_002, 4, :k) end)
        refute Map.has_key?(calls, {:erlang, :phash2, 2})
      end

      calls = Trace.calls([:erlang], fn -> Partition.oversized?(10_001, 40_002, 4, :k) end)
      assert calls[{:erlang, :phash2, 2}] == 1
    end
  end

  describe "ids carry the partition" do
    property "for n in 1, 2, 4, 8 every id allocated for a key has of_id equal to of_key of that key" do
      check all keys <- list_of(term(), min_length: 1, max_length: 50), n <- member_of(@ns) do
        ids = :atomics.new(n, signed: false)

        for key <- keys do
          id = Partition.next_id(ids, n, key)
          assert id >= 1
          assert Partition.of_id(id, n) == Partition.of_key(key, n)
        end
      end
    end

    property "Entry.put/4 and put_new/4 store ids whose partition is the key's" do
      check all keys <- uniq_list_of(term(), min_length: 1, max_length: 30),
                n <- member_of(@ns) do
        config = partitioned_config(n)

        for {key, i} <- Enum.with_index(keys) do
          if rem(i, 2) == 0,
            do: :ok = Entry.put(config, key, i, []),
            else: :ok = Entry.put_new(config, key, i, [])

          assert Partition.of_id(entry_id(config, key), n) == Partition.of_key(key, n)
        end

        :ets.delete(config.table)
      end
    end

    property "a key's ids increase" do
      check all keys <- list_of(member_of([:a, :b, :c, {:d, 1}, "e", 6]), max_length: 200),
                n <- member_of(@ns) do
        ids = :atomics.new(n, signed: false)

        last =
          Enum.reduce(keys, %{}, fn key, last ->
            id = Partition.next_id(ids, n, key)
            assert id > Map.get(last, key, 0)
            Map.put(last, key, id)
          end)

        # Distinct keys never share an id.
        assert map_size(last) == last |> Map.values() |> Enum.uniq() |> length()
      end
    end

    test "ids from concurrent writers are unique and increase per writer and key" do
      n = 4
      ids = :atomics.new(n, signed: false)
      keys = for i <- 1..16, do: {:k, i}

      per_writer =
        1..System.schedulers_online()
        |> Enum.map(fn _ ->
          Task.async(fn ->
            for _ <- 1..500, key <- keys, do: {key, Partition.next_id(ids, n, key)}
          end)
        end)
        |> Task.await_many()

      for allocations <- per_writer do
        allocations
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.each(fn {key, key_ids} ->
          assert key_ids == Enum.sort(key_ids)
          assert Enum.all?(key_ids, &(Partition.of_id(&1, n) == Partition.of_key(key, n)))
        end)
      end

      all = per_writer |> List.flatten() |> Enum.map(&elem(&1, 1))
      assert length(all) == length(Enum.uniq(all))
    end

    test "at n = 1 an id is the single counter's next value" do
      ids = :atomics.new(1, signed: false)
      assert for(key <- [:a, :b, :a, "c"], do: Partition.next_id(ids, 1, key)) == [1, 2, 3, 4]
    end
  end

  describe "no hash at n = 1" do
    test "of_key at n = 1 calls no hash" do
      # Loaded before tracing, so lazy loading adds nothing to the multiset.
      _ = Partition.of_key(:warm, 2)
      unpartitioned = Trace.calls([:erlang], fn -> 0 = Partition.of_key({:user, 7}, 1) end)
      refute Map.has_key?(unpartitioned, {:erlang, :phash2, 2})

      # The trace does see the hash where there is one.
      partitioned = Trace.calls([:erlang], fn -> Partition.of_key({:user, 7}, 2) end)
      assert partitioned[{:erlang, :phash2, 2}] == 1
    end

    test "put/4 and put_new/4 on a running cache call no hash" do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: :infinity})
      # Load the modules on the path first (Trace.calls/2 notes, M4.4).
      :ok = Theine.put(cache, :warm, 0)

      calls =
        Trace.calls([:erlang], fn ->
          :ok = Theine.put(cache, :new, 1)
          :ok = Theine.put_new(cache, :newer, 2)
          :ok = Theine.delete(cache, :new)
        end)

      refute Map.has_key?(calls, {:erlang, :phash2, 2})
      refute Map.has_key?(calls, {:erlang, :phash2, 1})
    end
  end

  describe "write events go to the partition their id carries" do
    test "deliver/2 counts each event in its partition's pending and sends it to that partition" do
      config = partitioned_config(4)
      register_forwarders(config)

      for {id, p} <- [{4, 0}, {5, 1}, {6, 2}, {7, 3}, {9, 1}] do
        assert WriteEvents.deliver(config, {:put, {:k, id}, id, 1, :infinity}) == :ok
        assert_receive {:partition, ^p, {:put, {:k, ^id}, ^id, 1, :infinity}}
      end

      assert WriteEvents.deliver(config, {:removed, {:k, 9}, 9}) == :ok
      assert_receive {:partition, 1, {:removed, {:k, 9}, 9}}

      assert for(p <- 1..4, do: :atomics.get(config.pending, p)) == [1, 3, 1, 1]
      refute_received {:partition, _, _}
    end

    test "put, put_new, expire, delete and an expired read reach the key's partition" do
      config = partitioned_config(4)
      register_forwarders(config)
      keys = for i <- 1..64, do: {:key, i}

      for key <- keys do
        p = Partition.of_key(key, 4)
        :ok = Entry.put(config, key, 1, [])
        id = entry_id(config, key)
        assert_receive {:partition, ^p, {:put, ^key, ^id, 1, :infinity}}

        true = Entry.expire(config, key, 60_000)
        assert_receive {:partition, ^p, {:put, ^key, ^id, 1, _expires_at}}

        :ok = Entry.delete(config, key)
        assert_receive {:partition, ^p, {:removed, ^key, ^id}}

        :ok = Entry.put_new(config, key, 2, ttl: 1)
        id = entry_id(config, key)
        assert_receive {:partition, ^p, {:put, ^key, ^id, 1, _}}

        # The expired-read branch, as `Theine.get/2` takes it once the ttl
        # has passed: removed by exact object and reported to the same
        # partition (specs/01 §Expired read).
        [entry] = :ets.lookup(config.table, key)
        :error = Entry.expired(config, entry)
        assert_receive {:partition, ^p, {:removed, ^key, ^id}}
      end

      refute_received {:partition, _, _}

      by_partition = Enum.frequencies_by(keys, &Partition.of_key(&1, 4))

      for p <- 0..3 do
        assert :atomics.get(config.pending, p + 1) == 5 * Map.get(by_partition, p, 0)
      end
    end

    test "backpressure is per partition: a writer above one partition's write_hwm calls only that partition" do
      config = partitioned_config(2, write_hwm: 1)
      register_forwarders(config)
      # Partition 1 is at its write_hwm; partition 0 has room.
      :atomics.put(config.pending, 2, 1)

      assert WriteEvents.deliver(config, {:put, :a, 2, 1, :infinity}) == :ok
      assert_receive {:partition, 0, {:put, :a, 2, 1, :infinity}}

      writer = Task.async(fn -> WriteEvents.deliver(config, {:put, :b, 3, 1, :infinity}) end)
      assert_receive {:partition, 1, {:"$gen_call", from, {:event, {:put, :b, 3, 1, :infinity}}}}
      GenServer.reply(from, :ok)
      assert Task.await(writer) == :ok
    end
  end

  describe "Theine.Owner allocates per partition" do
    test "one ids and one pending counter per partition" do
      for n <- @ns do
        cache = unique_cache()
        config = %{Config.new!(name: cache, max_size: :infinity) | partitions: n}
        start_supervised!({Theine.Owner, config}, id: cache)

        stored = Config.get(cache)
        assert :atomics.info(stored.ids).size == n
        assert :atomics.info(stored.pending).size == n
        assert stored.partitions == n
        stop_supervised!(cache)
      end
    end

    test "a default cache has one partition, under today's maintenance name" do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: 100})

      config = Config.get(cache)
      assert config.partitions == 1
      assert config.maintenances == {Theine.Maintenance.name(cache)}
      assert config.maintenance == Theine.Maintenance.name(cache)
      assert :atomics.info(config.ids).size == 1
      assert :atomics.info(config.pending).size == 1
    end
  end
end
