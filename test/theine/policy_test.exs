defmodule Theine.PolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Theine.{Config, Policy, Sketch, Stats}

  doctest Policy

  # The entries table the policy consults on a stale removal (specs/05
  # §Events `on_remove`). Named after the config's table, owned by the test
  # process, so it disappears with it; tests in one module run one at a time.
  # The runtime frees a dead owner's tables asynchronously, so the next
  # test's `:ets.new/2` could find the name still taken: each test waits
  # for its table to be gone before the next one starts.
  setup do
    config = config(:infinity)
    table = :ets.new(config.table, [:set, :public, :named_table])
    on_exit(fn -> await_table_gone(config.table) end)
    %{policy: Policy.new(config), sizes: config.sizes, table: table}
  end

  defp await_table_gone(name) do
    if :ets.whereis(name) != :undefined do
      Process.sleep(1)
      await_table_gone(name)
    end
  end

  # A config as Theine.Owner would complete it, without starting a cache:
  # the sizes atomics and the stats counters always, the sketch only under
  # a bound.
  defp config(max_size, opts \\ []) do
    config = Config.new!([name: :policy_test, max_size: max_size] ++ opts)

    %{
      config
      | sizes: :atomics.new(2, signed: true),
        counters: :counters.new(Stats.field_count(), [:write_concurrency]),
        sketch: if(is_integer(max_size), do: Sketch.new(max_size), else: nil)
    }
  end

  defp bounded(max_size, opts \\ []), do: Policy.new(config(max_size, opts))

  defp entry(key, id, weight \\ 1), do: {key, nil, id, weight, 0, :infinity}

  defp keys_in_order(policy, segment) do
    for {{^segment, _seq}, key} <- Policy.order_rows(policy), do: key
  end

  defp evictions(policy), do: :counters.get(policy.counters, Stats.evictions())

  defp total(policy), do: policy |> Policy.weights() |> Map.values() |> Enum.sum()

  # A put as the maintenance process sees it: the entry is in the table
  # before its event arrives.
  defp put(policy, table, key, id, weight \\ 1) do
    :ets.insert(table, entry(key, id, weight))
    Policy.on_write(policy, key, id, weight, :infinity)
  end

  # Raises the sketch frequency of `key` to `freq` (on_write counted it once).
  defp bump(policy, key, freq) do
    Enum.reduce(1..(freq - Sketch.frequency(policy.sketch, key))//1, policy, fn _, policy ->
      Sketch.increment(policy.sketch, key)
      policy
    end)
  end

  test "new/1 publishes zero sizes", %{sizes: sizes} do
    :atomics.put(sizes, 1, 5)
    policy = Policy.new(%{Config.new!(name: :policy_test, max_size: :infinity) | sizes: sizes})
    assert Policy.size(sizes) == 0
    assert Policy.weighted_size(sizes) == 0
    assert Policy.count(policy) == 0
  end

  describe "unbounded mode" do
    test "has no order table, no sketch and no limits", %{policy: policy} do
      assert policy.order == nil
      assert policy.sketch == nil
      assert policy.window_max == nil
      assert policy.protected_max == nil
      assert Policy.order_rows(policy) == []
      assert Policy.weights(policy) == %{window: 0, probation: 0, protected: 0}
    end

    test "segment weights stay at zero and rows carry segment nil", %{policy: policy} do
      policy = Policy.on_write(policy, :a, 1, 3, :infinity)
      policy = Policy.on_write(policy, :a, 2, 5, :infinity)
      assert {:ok, {:a, 2, nil, _, 5, :infinity}} = Policy.lookup(policy, :a)
      assert Policy.weights(policy) == %{window: 0, probation: 0, protected: 0}
      policy = Policy.on_remove(policy, :a, 2)
      assert Policy.weights(policy) == %{window: 0, probation: 0, protected: 0}
    end
  end

  describe "bounded mode" do
    test "limits/2 follows specs/05 §Regions and sizes" do
      assert Policy.limits(1_000, 1) == %{window_max: 10, main_max: 990, protected_max: 792}
      assert Policy.limits(1_000, 20) == %{window_max: 200, main_max: 800, protected_max: 640}
      assert Policy.limits(100, 1) == %{window_max: 1, main_max: 99, protected_max: 79}
      assert Policy.limits(1, 1) == %{window_max: 1, main_max: 0, protected_max: 0}
      assert Policy.limits(1, 80) == %{window_max: 1, main_max: 0, protected_max: 0}

      assert Policy.limits(1_000_000, 1) == %{
               window_max: 10_000,
               main_max: 990_000,
               protected_max: 792_000
             }
    end

    test "new/1 creates the order table, keeps the sketch and applies window_percent" do
      policy = bounded(1_000)
      assert :ets.info(policy.order, :type) == :ordered_set
      assert :ets.info(policy.order, :protection) == :private
      assert %Sketch{} = policy.sketch
      assert policy.window_max == 10
      assert policy.protected_max == 792
      assert policy.max_size == 1_000

      wide = bounded(1_000, window_percent: 50)
      assert wide.window_max == 500
      assert wide.protected_max == 400
    end

    test "new/1 clears a dirty sketch so a restarted process starts cold" do
      config = config(100)
      Sketch.increment(config.sketch, :a)
      assert Sketch.frequency(config.sketch, :a) == 1

      policy = Policy.new(config)
      assert Sketch.frequency(policy.sketch, :a) == 0
      assert policy.sketch_size == 0
    end

    test "a new key is placed at the window MRU and counted in the sketch" do
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 1, 3, :infinity)
      policy = Policy.on_write(policy, :b, 2, 4, 1_000)

      assert {:ok, {:a, 1, :window, 1, 3, :infinity}} = Policy.lookup(policy, :a)
      assert {:ok, {:b, 2, :window, 2, 4, 1_000}} = Policy.lookup(policy, :b)
      assert Policy.order_rows(policy) == [{{:window, 1}, :a}, {{:window, 2}, :b}]
      assert Policy.lru(policy, :window) == {:ok, :a}
      assert Policy.mru(policy, :window) == {:ok, :b}
      assert Policy.lru(policy, :probation) == :error
      assert Policy.mru(policy, :protected) == :error
      assert Policy.weights(policy) == %{window: 7, probation: 0, protected: 0}
      assert Policy.size(policy.sizes) == 2
      assert Policy.weighted_size(policy.sizes) == 7
      assert Sketch.frequency(policy.sketch, :a) == 1
      assert Sketch.frequency(policy.sketch, :b) == 1
      assert Sketch.frequency(policy.sketch, :c) == 0
      assert policy.sketch_size == 2
    end

    test "an overwrite with a new id moves the key to its segment's MRU and counts it", %{
      table: table
    } do
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 1, 3, :infinity)
      policy = Policy.on_write(policy, :b, 2, 1, :infinity)
      :ets.insert(table, entry(:a, 3, 5))
      policy = Policy.on_write(policy, :a, 3, 5, 2_000)

      assert {:ok, {:a, 3, :window, 3, 5, 2_000}} = Policy.lookup(policy, :a)
      assert keys_in_order(policy, :window) == [:b, :a]
      assert Policy.mru(policy, :window) == {:ok, :a}
      assert Policy.lru(policy, :window) == {:ok, :b}
      assert Policy.id_count(policy) == 2
      assert Policy.weights(policy) == %{window: 6, probation: 0, protected: 0}
      assert Policy.weighted_size(policy.sizes) == 6
      assert Sketch.frequency(policy.sketch, :a) == 2
      assert policy.sketch_size == 3

      # The old id is stale: removing by it is ignored while the key is live.
      policy = Policy.on_remove(policy, :a, 1)
      assert Policy.count(policy) == 2
      assert Policy.weights(policy) == %{window: 6, probation: 0, protected: 0}
    end

    test "an overwrite keeps the key in a non-window segment and moves it to that MRU" do
      # Rows are placed by hand in the main region, as on_access (M2.5) and
      # evict (M2.6) will place them, to pin the "current segment" rule.
      policy = bounded(100)
      policy = Policy.on_write(policy, :p1, 1, 2, :infinity)
      policy = Policy.on_write(policy, :p2, 2, 2, :infinity)
      policy = Policy.on_write(policy, :w, 3, 1, :infinity)
      policy = place(policy, :p1, :probation)
      policy = place(policy, :p2, :probation)
      assert keys_in_order(policy, :probation) == [:p1, :p2]

      policy = Policy.on_write(policy, :p1, 4, 3, :infinity)

      assert {:ok, {:p1, 4, :probation, _, 3, :infinity}} = Policy.lookup(policy, :p1)
      assert keys_in_order(policy, :probation) == [:p2, :p1]
      assert keys_in_order(policy, :window) == [:w]
      assert Policy.weights(policy) == %{window: 1, probation: 5, protected: 0}
      assert Policy.weighted_size(policy.sizes) == 6
    end

    test "a heavier rewrite of a protected key demotes the protected LRU until it fits", %{
      table: table
    } do
      # protected_max is 79 at max_size 100.
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 1, 30, :infinity)
      policy = Policy.on_write(policy, :b, 2, 30, :infinity)
      policy = Policy.on_write(policy, :c, 3, 1, :infinity)
      policy = Enum.reduce([:a, :b], policy, &place(&2, &1, :protected))

      # 40 + 30 fits: no demotion, a moves to the protected MRU.
      :ets.insert(table, entry(:a, 4, 40))
      policy = Policy.on_write(policy, :a, 4, 40, :infinity)
      assert keys_in_order(policy, :protected) == [:b, :a]
      assert Policy.weights(policy) == %{window: 1, probation: 0, protected: 70}

      # 40 + 50 does not: the LRU, a, is demoted to the probation MRU.
      :ets.insert(table, entry(:b, 5, 50))
      policy = Policy.on_write(policy, :b, 5, 50, :infinity)
      assert keys_in_order(policy, :protected) == [:b]
      assert keys_in_order(policy, :probation) == [:a]
      assert Policy.weights(policy) == %{window: 1, probation: 40, protected: 50}
      assert policy.protected_weight <= policy.protected_max

      # A same-id weight update (an expire/3-style event) is held to the
      # same limit, without an MRU move of its own.
      policy = place(policy, :a, :protected)
      assert keys_in_order(policy, :protected) == [:b, :a]
      policy = Policy.on_write(policy, :b, 5, 60, :infinity)
      assert keys_in_order(policy, :protected) == [:a]
      assert keys_in_order(policy, :probation) == [:b]
      assert Policy.weights(policy) == %{window: 1, probation: 60, protected: 40}
      assert Policy.weighted_size(policy.sizes) == 101
    end

    test "a rewrite heavier than protected_max moves the key to the probation MRU", %{
      table: table
    } do
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 1, 30, :infinity)
      policy = Policy.on_write(policy, :b, 2, 30, :infinity)
      policy = Policy.on_write(policy, :p, 3, 1, :infinity)
      policy = Enum.reduce([:a, :b], policy, &place(&2, &1, :protected))
      policy = place(policy, :p, :probation)

      :ets.insert(table, entry(:b, 4, 80))
      policy = Policy.on_write(policy, :b, 4, 80, :infinity)

      assert keys_in_order(policy, :protected) == [:a]
      assert keys_in_order(policy, :probation) == [:p, :b]
      assert {:ok, {:b, 4, :probation, _, 80, :infinity}} = Policy.lookup(policy, :b)
      assert Policy.weights(policy) == %{window: 0, probation: 81, protected: 30}
      assert Policy.weighted_size(policy.sizes) == 111
      assert length(Policy.order_rows(policy)) == 3
    end

    test "a same-id write updates weight and expires_at without a move or a sketch count" do
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 1, 3, :infinity)
      policy = Policy.on_write(policy, :b, 2, 1, :infinity)
      policy = Policy.on_write(policy, :a, 1, 4, 2_000)

      assert {:ok, {:a, 1, :window, 1, 4, 2_000}} = Policy.lookup(policy, :a)
      assert keys_in_order(policy, :window) == [:a, :b]
      assert Policy.weights(policy) == %{window: 5, probation: 0, protected: 0}
      assert Policy.weighted_size(policy.sizes) == 5
      assert Sketch.frequency(policy.sketch, :a) == 1
      assert policy.sketch_size == 2
    end

    test "on_remove with the current id deletes the order row and subtracts the segment weight" do
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 1, 3, :infinity)
      policy = Policy.on_write(policy, :b, 2, 4, :infinity)
      policy = place(policy, :b, :protected)
      policy = Policy.on_remove(policy, :a, 1)

      assert Policy.lookup(policy, :a) == :error
      assert Policy.order_rows(policy) == [{{:protected, 3}, :b}]
      assert Policy.weights(policy) == %{window: 0, probation: 0, protected: 4}
      assert Policy.size(policy.sizes) == 1
      assert Policy.weighted_size(policy.sizes) == 4

      policy = Policy.on_remove(policy, :b, 2)
      assert Policy.order_rows(policy) == []
      assert Policy.weights(policy) == %{window: 0, probation: 0, protected: 0}
      assert Policy.weighted_size(policy.sizes) == 0
    end

    test "on_remove with a stale id is ignored while the entries table holds the key", %{
      table: table
    } do
      :ets.insert(table, entry(:a, 2))
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 2, 3, :infinity)
      policy = Policy.on_remove(policy, :a, 1)
      policy = Policy.on_remove(policy, :a, 3)
      policy = Policy.on_remove(policy, :b, 2)

      assert {:ok, {:a, 2, :window, 1, 3, :infinity}} = Policy.lookup(policy, :a)
      assert Policy.order_rows(policy) == [{{:window, 1}, :a}]
      assert Policy.weights(policy) == %{window: 3, probation: 0, protected: 0}
      assert Policy.weighted_size(policy.sizes) == 3
    end

    test "on_remove with a stale id drops every row when the entries table lacks the key", %{
      table: table
    } do
      :ets.insert(table, entry(:a, 1))
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 1, 3, :infinity)
      policy = Policy.on_write(policy, :a, 2, 4, :infinity)
      :ets.delete(table, :a)

      policy = Policy.on_remove(policy, :a, 1)

      assert Policy.lookup(policy, :a) == :error
      assert Policy.order_rows(policy) == []
      assert Policy.id_count(policy) == 0
      assert Policy.weights(policy) == %{window: 0, probation: 0, protected: 0}
      assert Policy.weighted_size(policy.sizes) == 0
    end

    test "reset/1 empties the order table, zeroes the segment weights and clears the sketch" do
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 1, 3, :infinity)
      policy = Policy.on_write(policy, :b, 2, 3, :infinity)
      policy = place(policy, :b, :probation)

      policy = Policy.reset(policy)

      assert Policy.count(policy) == 0
      assert Policy.order_rows(policy) == []
      assert Policy.weights(policy) == %{window: 0, probation: 0, protected: 0}
      assert Policy.weighted_size(policy.sizes) == 0
      assert Sketch.frequency(policy.sketch, :a) == 0
      assert policy.sketch_size == 0
      # Still usable, and seq keeps increasing: order rows never collide.
      policy = Policy.on_write(policy, :a, 3, 1, :infinity)
      assert {:ok, {:a, 3, :window, seq, 1, :infinity}} = Policy.lookup(policy, :a)
      assert seq > 3
    end

    test "seq never reaches the sentinel: the write that would is refused" do
      policy = %{bounded(100) | next_seq: Policy.max_seq() - 1}
      policy = Policy.on_write(policy, :a, 1, 1, :infinity)
      assert Policy.mru(policy, :window) == {:ok, :a}
      assert policy.next_seq == Policy.max_seq()

      assert_raise RuntimeError, ~r/sentinel/, fn ->
        Policy.on_write(policy, :b, 2, 1, :infinity)
      end

      assert_raise RuntimeError, ~r/sentinel/, fn ->
        Policy.on_write(policy, :a, 3, 1, :infinity)
      end

      # Nothing was applied: the refused writes left every table as it was.
      assert Policy.count(policy) == 1
      assert Policy.id_count(policy) == 1
      assert Policy.order_rows(policy) == [{{:window, Policy.max_seq() - 1}, :a}]
      assert Policy.weighted_size(policy.sizes) == 1
    end

    test "order keys are small integers that keep the segments apart up to the sentinel" do
      # specs/05 §State: `base(segment) + seq` sorts by segment, then seq, and
      # never becomes a bignum, whose comparisons would cost the tree walk.
      last = Policy.max_seq() - 1

      for segment <- [:probation, :protected, :window] do
        assert :erts_debug.flat_size(Policy.order_key(segment, last)) == 0
      end

      assert Policy.order_key(:probation, last) < Policy.order_key(:protected, 1)
      assert Policy.order_key(:protected, last) < Policy.order_key(:window, 1)
      assert Policy.order_key(:window, last) < Bitwise.bsl(1, 59)
      assert_raise FunctionClauseError, fn -> Policy.order_key(:window, Policy.max_seq()) end
    end

    test "the sentinel sorts after every live order key" do
      policy = %{bounded(100) | next_seq: Policy.max_seq() - 2}
      policy = Policy.on_write(policy, :a, 1, 1, :infinity)
      policy = Policy.on_write(policy, :b, 2, 1, :infinity)
      assert Policy.mru(policy, :window) == {:ok, :b}
      assert Policy.lru(policy, :window) == {:ok, :a}
    end
  end

  describe "restore/5 (specs/04 §Restart semantics step 3)" do
    test "places a bounded entry at the probation MRU with its weight and expires_at, cold" do
      policy = bounded(100)
      policy = Policy.restore(policy, :a, 7, 3, 1_000)
      policy = Policy.restore(policy, :b, 8, 4, :infinity)

      assert {:ok, {:a, 7, :probation, seq_a, 3, 1_000}} = Policy.lookup(policy, :a)
      assert {:ok, {:b, 8, :probation, seq_b, 4, :infinity}} = Policy.lookup(policy, :b)
      assert seq_a < seq_b
      assert Policy.order_rows(policy) == [{{:probation, seq_a}, :a}, {{:probation, seq_b}, :b}]
      assert Policy.lru(policy, :probation) == {:ok, :a}
      assert Policy.mru(policy, :probation) == {:ok, :b}
      assert Policy.weights(policy) == %{window: 0, probation: 7, protected: 0}
      assert Policy.size(policy.sizes) == 2
      assert Policy.weighted_size(policy.sizes) == 7
      assert Policy.id_count(policy) == 2

      # No sketch increment: the rebuilt policy has no access history.
      assert policy.sketch_size == 0
      assert Sketch.frequency(policy.sketch, :a) == 0
      assert Sketch.frequency(policy.sketch, :b) == 0

      # A restored id is a current id: a read of it promotes as any would.
      policy = Policy.on_access(policy, 7)
      assert {:ok, {:a, 7, :protected, _, 3, 1_000}} = Policy.lookup(policy, :a)
    end

    test "restores an unbounded entry as a plain row", %{policy: policy, sizes: sizes} do
      policy = Policy.restore(policy, :a, 7, 3, 1_000)
      assert {:ok, {:a, 7, nil, _, 3, 1_000}} = Policy.lookup(policy, :a)
      assert Policy.order_rows(policy) == []
      assert Policy.weights(policy) == %{window: 0, probation: 0, protected: 0}
      assert Policy.size(sizes) == 1
      assert Policy.weighted_size(sizes) == 3
      assert Policy.id_count(policy) == 1
    end

    test "leaves a key the policy already holds alone" do
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 1, 2, :infinity)
      policy = Policy.restore(policy, :a, 1, 2, :infinity)
      policy = Policy.restore(policy, :a, 9, 5, :infinity)

      assert {:ok, {:a, 1, :window, _, 2, :infinity}} = Policy.lookup(policy, :a)
      assert Policy.count(policy) == 1
      assert Policy.id_count(policy) == 1
      assert length(Policy.order_rows(policy)) == 1
      assert Policy.weights(policy) == %{window: 2, probation: 0, protected: 0}
      assert Policy.size(policy.sizes) == 1
      assert Policy.weighted_size(policy.sizes) == 2
    end

    test "the later events settle a restored row: a newer put moves it, a removal drops it" do
      policy = bounded(100)
      policy = Policy.restore(policy, :a, 7, 1, :infinity)
      policy = Policy.restore(policy, :b, 8, 1, :infinity)

      # The entry's own event replayed after the rebuild is a same-id put:
      # weight and expiry only, no move, no count (specs/05 §Events).
      policy = Policy.on_write(policy, :a, 7, 2, 5_000)
      assert {:ok, {:a, 7, :probation, _, 2, 5_000}} = Policy.lookup(policy, :a)
      assert Policy.lru(policy, :probation) == {:ok, :a}
      assert policy.sketch_size == 0

      policy = Policy.on_write(policy, :a, 9, 2, :infinity)
      assert {:ok, {:a, 9, :probation, _, 2, :infinity}} = Policy.lookup(policy, :a)
      assert Policy.mru(policy, :probation) == {:ok, :a}
      assert policy.sketch_size == 1

      policy = Policy.on_remove(policy, :b, 8)
      assert Policy.lookup(policy, :b) == :error
      assert Policy.weights(policy) == %{window: 0, probation: 2, protected: 0}
      assert Policy.id_count(policy) == 1
    end

    test "the rebuilt weight can exceed max_size and evict/1 brings it back without candidates" do
      policy = bounded(10)

      policy =
        Enum.reduce(1..15, policy, fn i, policy -> Policy.restore(policy, i, i, 1, :infinity) end)

      assert Policy.weights(policy) == %{window: 0, probation: 15, protected: 0}
      assert {:done, 0, policy} = Policy.evict(policy)
      assert total(policy) == 10
      assert Policy.count(policy) == 10
      # The probation LRU end went first: the five restored earliest.
      for i <- 1..5, do: assert(Policy.lookup(policy, i) == :error)
      for i <- 6..15, do: assert({:ok, _} = Policy.lookup(policy, i))
    end

    # specs/05 §Decisions M2.12: a writer inserts, the rebuild restores the
    # entry, and its `:put` queued behind the scan is applied after the
    # eviction that removed it.
    test "a queued put for a restored entry evicted since does not bring its row back", %{
      table: table
    } do
      policy = bounded(10)
      for i <- 2..12, do: :ets.insert(table, entry(i, i))

      policy =
        Enum.reduce(2..12, policy, fn i, policy -> Policy.restore(policy, i, i, 1, :infinity) end)

      assert policy.restored_id == 12
      assert {:done, 1, policy} = Policy.evict(policy)
      assert :ets.lookup(table, 2) == []
      assert Policy.lookup(policy, 2) == :error

      # Key 2's own event, and a removal racing it, change nothing.
      policy = Policy.on_write(policy, 2, 2, 1, :infinity)
      policy = Policy.on_remove(policy, 2, 2)
      assert Policy.lookup(policy, 2) == :error
      assert Policy.count(policy) == 10
      assert Policy.size(policy.sizes) == 10
      assert Policy.weights(policy) == %{window: 0, probation: 10, protected: 0}

      # An entry inserted before the scan ended that the scan did not see
      # (its id is below the mark) is admitted, since the table holds it.
      :ets.insert(table, entry(:late, 1))
      policy = Policy.on_write(policy, :late, 1, 1, :infinity)
      assert {:ok, {:late, 1, :window, _, 1, :infinity}} = Policy.lookup(policy, :late)

      # Above the mark nothing is read from the table: a write after the
      # rebuild is applied as before.
      policy = Policy.on_write(policy, :fresh, 13, 1, :infinity)
      assert {:ok, {:fresh, 13, :window, _, 1, :infinity}} = Policy.lookup(policy, :fresh)
    end

    test "the restored-id mark only rises", %{policy: policy} do
      policy = Policy.restore(policy, :a, 9, 1, :infinity)
      policy = Policy.restore(policy, :b, 4, 1, :infinity)
      policy = Policy.restore(policy, :a, 20, 1, :infinity)
      assert policy.restored_id == 9
      assert bounded(10).restored_id == 0
    end
  end

  describe "on_access/2" do
    test "moves a window key to the window MRU and counts it" do
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 1, 2, :infinity)
      policy = Policy.on_write(policy, :b, 2, 1, :infinity)
      policy = Policy.on_write(policy, :c, 3, 1, :infinity)

      policy = Policy.on_access(policy, 1)

      assert keys_in_order(policy, :window) == [:b, :c, :a]
      assert {:ok, {:a, 1, :window, seq, 2, :infinity}} = Policy.lookup(policy, :a)
      assert seq == 4
      assert policy.next_seq == 5
      assert Policy.weights(policy) == %{window: 4, probation: 0, protected: 0}
      assert Policy.weighted_size(policy.sizes) == 4
      assert Sketch.frequency(policy.sketch, :a) == 2
      assert policy.sketch_size == 4
    end

    test "promotes a probation entry to protected and demotes when over protected_max" do
      # protected_max is 79 at max_size 100 (specs/05 §Regions and sizes).
      policy = bounded(100)
      policy = Policy.on_write(policy, :w, 1, 1, :infinity)
      policy = Policy.on_write(policy, :p1, 2, 30, :infinity)
      policy = Policy.on_write(policy, :p2, 3, 30, :infinity)
      policy = Policy.on_write(policy, :p3, 4, 30, :infinity)
      policy = Policy.on_write(policy, :p4, 5, 5, :infinity)
      policy = Enum.reduce([:p1, :p2, :p3, :p4], policy, &place(&2, &1, :probation))
      assert Policy.weights(policy) == %{window: 1, probation: 95, protected: 0}

      policy = Policy.on_access(policy, 2)
      assert keys_in_order(policy, :probation) == [:p2, :p3, :p4]
      assert keys_in_order(policy, :protected) == [:p1]
      assert {:ok, {:p1, 2, :protected, _, 30, :infinity}} = Policy.lookup(policy, :p1)
      assert Policy.weights(policy) == %{window: 1, probation: 65, protected: 30}
      assert Sketch.frequency(policy.sketch, :p1) == 2

      policy = Policy.on_access(policy, 3)
      assert keys_in_order(policy, :probation) == [:p3, :p4]
      assert keys_in_order(policy, :protected) == [:p1, :p2]
      assert Policy.weights(policy) == %{window: 1, probation: 35, protected: 60}

      # 90 > 79: the protected LRU (p1) is demoted to the probation MRU,
      # behind p4, and the accessed key stays at the protected MRU.
      policy = Policy.on_access(policy, 4)
      assert keys_in_order(policy, :probation) == [:p4, :p1]
      assert keys_in_order(policy, :protected) == [:p2, :p3]
      assert {:ok, {:p1, 2, :probation, _, 30, :infinity}} = Policy.lookup(policy, :p1)
      assert Policy.mru(policy, :protected) == {:ok, :p3}
      assert Policy.weights(policy) == %{window: 1, probation: 35, protected: 60}
      assert Policy.weighted_size(policy.sizes) == 96
      assert Policy.size(policy.sizes) == 5
      assert Policy.count(policy) == 5
      assert length(Policy.order_rows(policy)) == 5
      assert policy.sketch_size == 8
    end

    test "demotes as many protected LRU entries as it takes to fit" do
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 1, 20, :infinity)
      policy = Policy.on_write(policy, :b, 2, 20, :infinity)
      policy = Policy.on_write(policy, :c, 3, 20, :infinity)
      policy = Policy.on_write(policy, :d, 4, 70, :infinity)
      policy = Enum.reduce([:a, :b, :c], policy, &place(&2, &1, :protected))
      policy = place(policy, :d, :probation)
      assert Policy.weights(policy) == %{window: 0, probation: 70, protected: 60}

      # 130 > 79, and 110 and 90 still are: a, b and c are all demoted, in
      # LRU order, and the protected segment is left with d at 70.
      policy = Policy.on_access(policy, 4)

      assert keys_in_order(policy, :protected) == [:d]
      assert keys_in_order(policy, :probation) == [:a, :b, :c]
      assert Policy.weights(policy) == %{window: 0, probation: 60, protected: 70}
      assert Policy.weighted_size(policy.sizes) == 130
    end

    test "moves a protected key to the protected MRU" do
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 1, 1, :infinity)
      policy = Policy.on_write(policy, :b, 2, 1, :infinity)
      policy = Policy.on_write(policy, :c, 3, 1, :infinity)
      policy = Enum.reduce([:a, :b], policy, &place(&2, &1, :protected))
      policy = place(policy, :c, :probation)

      policy = Policy.on_access(policy, 1)

      assert keys_in_order(policy, :protected) == [:b, :a]
      assert keys_in_order(policy, :probation) == [:c]
      assert Policy.weights(policy) == %{window: 0, probation: 1, protected: 2}
      assert Sketch.frequency(policy.sketch, :a) == 2
      assert policy.sketch_size == 4
    end

    test "a probation entry heavier than protected_max moves to the probation MRU instead" do
      policy = bounded(100)
      policy = Policy.on_write(policy, :other, 1, 10, :infinity)
      policy = Policy.on_write(policy, :big, 2, 80, :infinity)
      policy = Policy.on_write(policy, :small, 3, 1, :infinity)
      policy = place(policy, :other, :protected)
      policy = place(policy, :big, :probation)
      policy = place(policy, :small, :probation)
      assert keys_in_order(policy, :probation) == [:big, :small]

      policy = Policy.on_access(policy, 2)

      assert keys_in_order(policy, :probation) == [:small, :big]
      assert keys_in_order(policy, :protected) == [:other]
      assert {:ok, {:big, 2, :probation, _, 80, :infinity}} = Policy.lookup(policy, :big)
      assert Policy.weights(policy) == %{window: 0, probation: 81, protected: 10}
      assert Sketch.frequency(policy.sketch, :big) == 2

      # Exactly protected_max still fits.
      policy = Policy.on_write(policy, :fit, 4, 79, :infinity)
      policy = place(policy, :fit, :probation)
      policy = Policy.on_access(policy, 4)
      assert keys_in_order(policy, :protected) == [:fit]
      assert keys_in_order(policy, :probation) == [:small, :big, :other]
      assert Policy.weights(policy) == %{window: 0, probation: 91, protected: 79}
    end

    test "with an old id after the key was rewritten has no effect", %{table: table} do
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 1, 1, :infinity)
      policy = Policy.on_write(policy, :b, 2, 1, :infinity)
      :ets.insert(table, entry(:a, 3))
      policy = Policy.on_write(policy, :a, 3, 1, :infinity)
      policy = Policy.on_access(policy, 2)
      assert keys_in_order(policy, :window) == [:a, :b]
      before = policy

      policy = Policy.on_access(policy, 1)

      assert policy == before
      assert keys_in_order(policy, :window) == [:a, :b]
      assert Policy.order_rows(policy) == Policy.order_rows(before)
      assert Sketch.frequency(policy.sketch, :a) == 2
      assert policy.sketch_size == 4
    end

    test "with an unknown or removed id has no effect" do
      policy = bounded(100)
      policy = Policy.on_write(policy, :a, 1, 1, :infinity)
      policy = Policy.on_write(policy, :b, 2, 1, :infinity)
      policy = Policy.on_remove(policy, :b, 2)
      before = policy

      policy = policy |> Policy.on_access(2) |> Policy.on_access(99)

      assert policy == before
      assert Policy.order_rows(policy) == [{{:window, 1}, :a}]
      assert Policy.weights(policy) == %{window: 1, probation: 0, protected: 0}
      assert policy.sketch_size == 2
    end

    test "is a no-op without a bound", %{policy: policy, sizes: sizes} do
      policy = Policy.on_write(policy, :a, 1, 3, :infinity)
      before = policy

      policy = policy |> Policy.on_access(1) |> Policy.on_access(2)

      assert policy == before
      assert Policy.lookup(policy, :a) == {:ok, {:a, 1, nil, 1, 3, :infinity}}
      assert Policy.weighted_size(sizes) == 3
    end

    test "refuses the move that would reach the seq sentinel" do
      policy = %{bounded(100) | next_seq: Policy.max_seq() - 1}
      policy = Policy.on_write(policy, :a, 1, 1, :infinity)

      assert_raise RuntimeError, ~r/sentinel/, fn -> Policy.on_access(policy, 1) end

      assert Policy.order_rows(policy) == [{{:window, Policy.max_seq() - 1}, :a}]
      assert Sketch.frequency(policy.sketch, :a) == 1
    end
  end

  describe "evict/1" do
    # max_size 10: window_max 1, main_max 9, protected_max 7. Nine keys
    # placed in probation fill the main region, so the next window overflow
    # forces one admission decision against the probation LRU, p1.
    defp main_full(policy, table) do
      Enum.reduce(1..9, policy, fn i, policy ->
        policy |> put(table, :"p#{i}", i) |> place(:"p#{i}", :probation)
      end)
    end

    defp probation_keys(n), do: for(i <- 1..n, do: :"p#{i}")

    test "overflows the window LRU entries to the probation MRU on every call", %{table: table} do
      policy = bounded(100) |> put(table, :a, 1) |> put(table, :b, 2) |> put(table, :c, 3)
      assert Policy.weights(policy) == %{window: 3, probation: 0, protected: 0}

      assert {:done, 0, policy} = Policy.evict(policy)

      assert keys_in_order(policy, :window) == [:c]
      assert keys_in_order(policy, :probation) == [:a, :b]
      assert Policy.mru(policy, :probation) == {:ok, :b}
      assert Policy.weights(policy) == %{window: 1, probation: 2, protected: 0}
      assert {:ok, {:a, 1, :probation, _, 1, :infinity}} = Policy.lookup(policy, :a)
      assert policy.candidates == 0
      assert policy.cursor == nil
      assert evictions(policy) == 0
      assert :ets.info(table, :size) == 3
      assert Policy.size(policy.sizes) == 3

      # Nothing to do is nothing done.
      assert {:done, 0, ^policy} = Policy.evict(policy)
    end

    test "victim freq 3 vs candidate freq 5 evicts the victim", %{table: table} do
      policy = bounded(10) |> main_full(table) |> put(table, :c, 10) |> put(table, :w, 11)
      policy = policy |> bump(:p1, 3) |> bump(:c, 5)
      assert total(policy) == 11

      assert {:done, 1, policy} = Policy.evict(policy)

      assert :ets.lookup(table, :p1) == []
      assert Policy.lookup(policy, :p1) == :error
      assert keys_in_order(policy, :probation) == (probation_keys(9) -- [:p1]) |> Kernel.++([:c])
      assert keys_in_order(policy, :window) == [:w]
      assert total(policy) == 10
      assert Policy.weights(policy) == %{window: 1, probation: 9, protected: 0}
      assert Policy.size(policy.sizes) == 10
      assert Policy.weighted_size(policy.sizes) == 10
      assert Policy.id_count(policy) == 10
      assert :ets.info(table, :size) == 10
      assert evictions(policy) == 1
      assert policy.candidates == 0
      assert policy.cursor == nil
    end

    test "victim freq 5 vs candidate freq 3 evicts the candidate", %{table: table} do
      policy = bounded(10) |> main_full(table) |> put(table, :c, 10) |> put(table, :w, 11)
      policy = policy |> bump(:p1, 5) |> bump(:c, 3)

      assert {:done, 1, policy} = Policy.evict(policy)

      assert :ets.lookup(table, :c) == []
      assert Policy.lookup(policy, :c) == :error
      assert [{:p1, nil, 1, 1, 0, :infinity}] = :ets.lookup(table, :p1)
      assert keys_in_order(policy, :probation) == probation_keys(9)
      assert keys_in_order(policy, :window) == [:w]
      assert total(policy) == 10
      assert evictions(policy) == 1
      assert Policy.id_count(policy) == 10
    end

    test "victim freq 2 vs candidate freq 2 evicts the candidate", %{table: table} do
      policy = bounded(10) |> main_full(table) |> put(table, :c, 10) |> put(table, :w, 11)
      policy = policy |> bump(:p1, 2) |> bump(:c, 2)

      assert {:done, 1, policy} = Policy.evict(policy)

      assert :ets.lookup(table, :c) == []
      assert keys_in_order(policy, :probation) == probation_keys(9)
      assert evictions(policy) == 1
    end

    test "a tied candidate of frequency 6 or more is admitted about one time in 128", %{
      table: table
    } do
      :rand.seed(:exsss, {2026, 10, 28})
      # max_size 2: window_max 1, main_max 1. One probation victim, one
      # window overflow, one decision per trial.
      policy = bounded(2)

      admitted = fn policy, freq, trials ->
        Enum.reduce(1..trials, {policy, 0}, fn _, {policy, admitted} ->
          :ets.delete_all_objects(table)

          policy =
            policy
            |> Policy.reset()
            |> put(table, :v, 1)
            |> place(:v, :probation)
            |> put(table, :c, 2)
            |> put(table, :w, 3)
            |> bump(:v, freq)
            |> bump(:c, freq)

          assert {:done, 1, policy} = Policy.evict(policy)
          assert total(policy) == 2
          {policy, admitted + if(:ets.member(table, :v), do: 0, else: 1)}
        end)
      end

      # 2_000 draws at 1/128: 15.6 expected, P(none) is about 2e-7 and
      # P(more than 60) smaller still.
      {policy, admitted_at_6} = admitted.(policy, 6, 2_000)
      assert admitted_at_6 in 1..60

      {_policy, admitted_at_5} = admitted.(policy, 5, 500)
      assert admitted_at_5 == 0
    end

    test "with no candidate the probation LRU is removed without an admission test", %{
      table: table
    } do
      policy =
        bounded(10)
        |> main_full(table)
        |> put(table, :x, 10)
        |> place(:x, :probation)
        |> put(table, :y, 11)
        |> place(:y, :probation)
        |> bump(:p1, 10)

      assert policy.window_weight == 0
      assert total(policy) == 11

      assert {:done, 1, policy} = Policy.evict(policy)

      assert :ets.lookup(table, :p1) == []
      assert Policy.lookup(policy, :p1) == :error
      assert keys_in_order(policy, :probation) == (probation_keys(9) -- [:p1]) ++ [:x, :y]
      assert total(policy) == 10
      assert evictions(policy) == 1
    end

    test "an empty probation falls back to the protected LRU, then to the window LRU", %{
      table: table
    } do
      policy =
        bounded(10)
        |> put(table, :a, 1, 5)
        |> place(:a, :protected)
        |> put(table, :b, 2, 5)
        |> place(:b, :protected)
        |> put(table, :w, 3)

      assert Policy.weights(policy) == %{window: 1, probation: 0, protected: 10}

      assert {:done, 1, policy} = Policy.evict(policy)

      assert :ets.lookup(table, :a) == []
      assert keys_in_order(policy, :protected) == [:b]
      assert keys_in_order(policy, :window) == [:w]
      assert Policy.weights(policy) == %{window: 1, probation: 0, protected: 5}
      assert evictions(policy) == 1

      # Step 1 empties any window over max_size before step 2 runs, so the
      # window fallback needs a window limit above the bound to be reached.
      policy = %{bounded(10) | window_max: 100}
      policy = Enum.reduce(1..12, policy, &put(&2, table, :"k#{&1}", &1))
      assert Policy.weights(policy) == %{window: 12, probation: 0, protected: 0}

      assert {:done, 2, policy} = Policy.evict(policy)

      assert :ets.lookup(table, :k1) == []
      assert :ets.lookup(table, :k2) == []
      assert keys_in_order(policy, :window) == for(i <- 3..12, do: :"k#{i}")
      assert Policy.weights(policy) == %{window: 10, probation: 0, protected: 0}
    end

    test "evict_batch caps a call and :more carries the untested candidates to the next", %{
      table: table
    } do
      policy = bounded(10, evict_batch: 2) |> main_full(table)
      policy = Enum.reduce(probation_keys(9), policy, &bump(&2, &1, 3))

      policy =
        policy
        |> put(table, :c1, 10)
        |> put(table, :c2, 11)
        |> put(table, :c3, 12)
        |> put(table, :c4, 13)
        |> put(table, :w, 14)

      assert total(policy) == 14

      # Four overflows; the two freshest are tested (and rejected, 1 < 3)
      # before the cap. The other two are still candidates.
      assert {:more, 2, policy} = Policy.evict(policy)

      assert :ets.lookup(table, :c4) == []
      assert :ets.lookup(table, :c3) == []
      assert keys_in_order(policy, :probation) == probation_keys(9) ++ [:c1, :c2]
      assert keys_in_order(policy, :window) == [:w]
      assert total(policy) == 12
      assert policy.candidates == 2
      assert {:ok, {:c2, 11, :probation, seq, 1, :infinity}} = Policy.lookup(policy, :c2)
      assert policy.cursor == seq
      assert evictions(policy) == 2

      # The follow-up continues with c2 and c1 rather than evicting p1 and
      # p2 outright as it would with the count reset.
      assert {:done, 2, policy} = Policy.evict(policy)

      assert :ets.lookup(table, :c2) == []
      assert :ets.lookup(table, :c1) == []
      assert [_] = :ets.lookup(table, :p1)
      assert keys_in_order(policy, :probation) == probation_keys(9)
      assert total(policy) == 10
      assert policy.candidates == 0
      assert policy.cursor == nil
      assert evictions(policy) == 4
      assert Policy.size(policy.sizes) == 10
      assert :ets.info(table, :size) == 10
    end

    test "a follow-up whose window overflowed again restarts the cursor at the probation MRU",
         %{table: table} do
      policy = bounded(10, evict_batch: 1)
      policy = Enum.reduce(1..8, policy, &(&2 |> put(table, :"p#{&1}", &1) |> bump(:"p#{&1}", 3)))
      policy = Enum.reduce(1..8, policy, &place(&2, :"p#{&1}", :probation))

      policy =
        policy
        |> put(table, :c1, 9)
        |> put(table, :c2, 10)
        |> put(table, :c3, 11)
        |> put(table, :w, 12)

      assert {:more, 1, policy} = Policy.evict(policy)
      assert :ets.lookup(table, :c3) == []
      assert policy.candidates == 2
      assert {:ok, {:c2, 10, :probation, c2_seq, 1, :infinity}} = Policy.lookup(policy, :c2)
      assert policy.cursor == c2_seq

      # A write between passes: the next call overflows w, the window LRU,
      # and tests it first, before the carried c2 and c1.
      policy = put(policy, table, :c4, 13)
      assert keys_in_order(policy, :window) == [:w, :c4]

      assert {:more, 1, policy} = Policy.evict(policy)

      assert :ets.lookup(table, :w) == []
      assert [_] = :ets.lookup(table, :c2)
      assert [_] = :ets.lookup(table, :c1)
      assert keys_in_order(policy, :window) == [:c4]
      assert policy.candidates == 2
      assert policy.cursor == c2_seq

      # The carried c2 is next; with it gone the weight fits and c1, never
      # tested, stays as a settled probation entry.
      assert {:done, 1, policy} = Policy.evict(policy)
      assert :ets.lookup(table, :c2) == []
      assert [_] = :ets.lookup(table, :c1)
      assert keys_in_order(policy, :probation) == probation_keys(8) ++ [:c1]
      assert total(policy) == 10
      assert evictions(policy) == 3
      assert policy.candidates == 0
    end

    test "a walk that reaches the batch's floor with candidates left settles them", %{
      table: table
    } do
      # Two carried candidates, but one of them is promoted between passes:
      # the count outlives its entries. The walk stops at the first
      # overflow's seq instead of retesting p9, and the victim goes.
      policy = bounded(10, evict_batch: 1) |> main_full(table)
      policy = Enum.reduce(probation_keys(9), policy, &bump(&2, &1, 3))
      policy = policy |> put(table, :c1, 10) |> put(table, :c2, 11) |> put(table, :c3, 12)
      policy = policy |> put(table, :w, 13)

      assert {:more, 1, policy} = Policy.evict(policy)
      assert :ets.lookup(table, :c3) == []
      assert policy.candidates == 2
      assert {:ok, {:c1, 10, :probation, c1_seq, 1, :infinity}} = Policy.lookup(policy, :c1)
      assert policy.candidate_floor == c1_seq

      policy = Policy.on_access(policy, 11)
      assert keys_in_order(policy, :protected) == [:c2]
      assert keys_in_order(policy, :probation) == probation_keys(9) ++ [:c1]

      assert {:more, 1, policy} = Policy.evict(policy)
      assert :ets.lookup(table, :c1) == []
      assert policy.candidates == 1
      assert {:ok, {:p9, 9, :probation, p9_seq, 1, :infinity}} = Policy.lookup(policy, :p9)
      assert policy.cursor == p9_seq
      assert policy.candidate_floor == c1_seq

      assert {:done, 1, policy} = Policy.evict(policy)
      assert :ets.lookup(table, :p1) == []
      assert [_] = :ets.lookup(table, :p9)
      assert policy.candidates == 0
      assert policy.cursor == nil
      assert policy.candidate_floor == nil
      assert total(policy) == 10
    end

    test "removal by stale id leaves a concurrently rewritten entry in place", %{table: table} do
      policy =
        bounded(10)
        |> main_full(table)
        |> put(table, :x, 10)
        |> place(:x, :probation)
        |> put(table, :y, 11)
        |> place(:y, :probation)

      assert total(policy) == 11

      # A put of p1 whose {:put, :p1, 99, ...} event is still in flight.
      :ets.insert(table, entry(:p1, 99))

      assert {:done, 0, policy} = Policy.evict(policy)

      assert Policy.lookup(policy, :p1) == :error
      assert [{:p1, nil, 99, 1, 0, :infinity}] = :ets.lookup(table, :p1)
      assert evictions(policy) == 0
      assert total(policy) == 10
      assert Policy.size(policy.sizes) == 10

      # The in-flight event re-admits the fresh version as a new key.
      policy = Policy.on_write(policy, :p1, 99, 1, :infinity)
      assert {:ok, {:p1, 99, :window, _, 1, :infinity}} = Policy.lookup(policy, :p1)
      assert Policy.id_count(policy) == 11
      assert total(policy) == 11

      # And a key the table no longer holds (its {:removed, ...} in flight)
      # only loses its rows.
      :ets.delete(table, :p2)
      policy = put(policy, table, :z, 12) |> place(:z, :probation)
      assert {:done, 1, policy} = Policy.evict(policy)
      assert Policy.lookup(policy, :p2) == :error
      assert evictions(policy) == 1
      assert total(policy) == 10
      policy = Policy.on_remove(policy, :p2, 2)
      assert total(policy) == 10
    end

    test "is a no-op without a bound", %{policy: policy, table: table} do
      policy = policy |> put(table, :a, 1) |> put(table, :b, 2)
      assert {:done, 0, ^policy} = Policy.evict(policy)
      assert :ets.info(table, :size) == 2
    end

    test "reset/1 clears the carried candidates and cursor", %{table: table} do
      policy = bounded(10, evict_batch: 1) |> main_full(table)
      policy = policy |> put(table, :c1, 10) |> put(table, :c2, 11) |> put(table, :w, 12)
      assert {:more, 1, policy} = Policy.evict(policy)
      assert policy.candidates == 1
      assert is_integer(policy.cursor)

      policy = Policy.reset(policy)

      assert policy.candidates == 0
      assert policy.cursor == nil
    end

    @tag timeout: 120_000
    test "scan resistance: an 800-key working set retains at least 90% after a 100_000-key scan",
         %{table: table} do
      policy = bounded(1_000)
      working = for i <- 1..800, do: {:hot, i}

      policy =
        Enum.reduce(
          Enum.with_index(working, 1),
          policy,
          &write(&2, table, elem(&1, 0), elem(&1, 1))
        )

      policy =
        Enum.reduce(1..9, policy, fn _, policy ->
          Enum.reduce(1..800, policy, fn id, policy -> policy |> Policy.on_access(id) |> age() end)
        end)

      # The ten most recent hot keys sit in the window (window_max 10); the
      # other 790 were promoted, under protected_max 792.
      assert length(keys_in_order(policy, :protected)) == 790
      assert length(keys_in_order(policy, :window)) == 10

      policy =
        Enum.reduce(1..100_000, policy, fn i, policy ->
          write(policy, table, {:scan, i}, 800 + i)
        end)

      # The 790 in protected are never victims while probation has an
      # entry; the 10 that were still in the window overflow alone into an
      # empty probation and are their own victim.
      retained = Enum.count(working, &:ets.member(table, &1))
      assert retained >= 720
      assert retained == 790
      assert total(policy) <= 1_000
      assert Policy.size(policy.sizes) == :ets.info(table, :size)
      assert Policy.count(policy) == :ets.info(table, :size)
    end
  end

  describe "adaptive window (specs/05 §Adaptive window)" do
    test "climb/1 waits for a full sample, then steps by 6.25% of max_size, smaller first", %{
      table: table
    } do
      # window_max 100, protected_max 720; the sample is 10 * 1_000 requests.
      policy = bounded(1_000, window_percent: 10)
      policy = Enum.reduce(1..100, policy, &put(&2, table, &1, &1))
      assert %{window_max: 100, sample_misses: 100, sample_hits: 0} = Policy.climber(policy)

      assert Policy.climb(policy) == policy

      # A rate of 0.49 against the initial 0 is no worse: the step keeps its
      # initial direction, toward a smaller window, and the 49-point change
      # restarts it at the full 62.5.
      policy = Policy.climb(%{policy | sample_hits: 4_900, sample_misses: 5_100})
      assert %{window_max: 38, protected_max: 782, sample_hits: 0} = Policy.climber(policy)
      assert policy.climber.step == -62.5
      assert policy.climber.adjustment == 0
      assert keys_in_order(policy, :window) == Enum.to_list(63..100)
      assert keys_in_order(policy, :probation) == Enum.to_list(1..62)
      assert Policy.weights(policy) == %{window: 38, probation: 62, protected: 0}

      # A slightly worse rate reverses the step and decays it by 0.98.
      policy = Policy.climb(%{policy | sample_hits: 4_800, sample_misses: 5_200})
      assert %{window_max: 100, protected_max: 720} = Policy.climber(policy)
      assert_in_delta policy.climber.step, 61.25, 1.0e-9
      assert Policy.weights(policy) == %{window: 100, probation: 0, protected: 0}
    end

    test "resize/2 grows the window from the probation LRU, then the protected LRU", %{
      table: table
    } do
      policy = bounded(100)
      # window_max 1, protected_max 79.
      policy = Enum.reduce(1..6, policy, &put(&2, table, &1, &1))
      policy = Enum.reduce(1..3, policy, &place(&2, &1, :probation))
      policy = Enum.reduce(4..5, policy, &place(&2, &1, :protected))

      policy = Policy.resize(policy, 4)

      # Probation 1..3 first, then the protected LRU 4, each to the window MRU.
      assert keys_in_order(policy, :window) == [6, 1, 2, 3, 4]
      assert keys_in_order(policy, :protected) == [5]
      assert %{window_max: 5, protected_max: 75} = Policy.climber(policy)
      assert policy.climber.adjustment == 0

      # With main holding one entry, a larger step moves only that one, and
      # the limits move by what was moved.
      policy = Policy.resize(policy, 10)
      assert %{window_max: 6, protected_max: 74} = Policy.climber(policy)
      assert policy.climber.adjustment == 9
      assert Policy.weights(policy) == %{window: 6, probation: 0, protected: 0}
    end

    test "resize/2 demotes the protected LRU when the smaller protected_max no longer fits", %{
      table: table
    } do
      # max_size 10: window_max 1, protected_max 7.
      policy = bounded(10)
      policy = Enum.reduce(1..8, policy, &put(&2, table, &1, &1))
      policy = Enum.reduce(1..7, policy, &place(&2, &1, :protected))

      policy = Policy.resize(policy, 3)

      # protected_max drops to 4: keys 1..3 are demoted to probation, then
      # moved on to the window MRU behind key 8.
      assert %{window_max: 4, protected_max: 4} = Policy.climber(policy)
      assert keys_in_order(policy, :window) == [8, 1, 2, 3]
      assert keys_in_order(policy, :protected) == [4, 5, 6, 7]
      assert policy.protected_weight <= policy.protected_max
    end

    test "resize/2 shrinks the window from its LRU to the probation MRU, never below 1", %{
      table: table
    } do
      policy = bounded(100, window_percent: 10)
      # window_max 10, protected_max 72.
      policy = Enum.reduce(1..10, policy, &put(&2, table, &1, &1))

      policy = Policy.resize(policy, -4)
      assert keys_in_order(policy, :window) == Enum.to_list(5..10)
      assert keys_in_order(policy, :probation) == [1, 2, 3, 4]
      assert %{window_max: 6, protected_max: 76} = Policy.climber(policy)

      policy = Policy.resize(policy, -50)
      assert keys_in_order(policy, :window) == [10]
      assert %{window_max: 1, protected_max: 81} = Policy.climber(policy)
      assert policy.climber.adjustment == 0

      # At the floor the step waits in the adjustment.
      policy = Policy.resize(policy, -3)
      assert %{window_max: 1, protected_max: 81} = Policy.climber(policy)
      assert policy.climber.adjustment == -3
    end

    test "resize/2 moves at most 1_000 entries per call and leaves the rest for the next", %{
      table: table
    } do
      policy = bounded(10_000, window_percent: 20)
      policy = Enum.reduce(1..2_000, policy, &put(&2, table, &1, &1))

      policy = Policy.resize(policy, -1_500)
      assert %{window_max: 1_000} = Policy.climber(policy)
      assert policy.climber.adjustment == -500
      assert policy.window_weight == 1_000

      policy = Policy.resize(policy, policy.climber.adjustment)
      assert %{window_max: 500} = Policy.climber(policy)
      assert policy.climber.adjustment == 0
    end

    test "adaptive: false keeps climb/1 a no-op and the limits fixed", %{table: table} do
      policy = bounded(1_000, adaptive: false)
      policy = Enum.reduce(1..10, policy, &put(&2, table, &1, &1))
      policy = %{policy | sample_hits: 9_000, sample_misses: 1_000}
      assert Policy.climb(policy) == policy
      assert %{adaptive: false, window_max: 10, protected_max: 792} = Policy.climber(policy)
    end

    test "reset/1 restarts the climber at the configured window", %{table: table} do
      policy = bounded(100, window_percent: 10)
      policy = Enum.reduce(1..10, policy, &put(&2, table, &1, &1))
      policy = Policy.climb(%{policy | sample_hits: 600, sample_misses: 400})
      assert %{window_max: 4} = Policy.climber(policy)

      policy = Policy.reset(policy)

      assert %{window_max: 10, protected_max: 72, sample_hits: 0, sample_misses: 0} =
               Policy.climber(policy)

      assert policy.climber.step == -6.25
      assert policy.climber.hit_rate == 0.0
    end

    test "the climber samples with stats: false" do
      # The sample is counted in the maintenance process from drained reads
      # and new-key puts, never from the stats counters (specs/05 §Adaptive
      # window). window_max 10, protected_max 72, a sample of 1_000.
      cache = :policy_test_climber

      start_supervised!(
        {Theine,
         name: cache,
         max_size: 100,
         window_percent: 10,
         stats: false,
         maintenance_interval: 3_600_000}
      )

      assert Config.get(cache).request_counters == nil
      for key <- 1..10, do: :ok = Theine.put(cache, key, key)

      # Batches of 30 reads, below the drain threshold and the ring's size,
      # so the pass after each drains every one of them.
      for _ <- 1..3 do
        for key <- 1..10, do: {:ok, ^key} = Theine.get(cache, key)
        :ok = Theine.Maintenance.run(cache)
      end

      # A miss with no put, and an overwrite, count for neither side.
      :error = Theine.get(cache, :absent)
      :ok = Theine.put(cache, 1, :again)
      :ok = Theine.Maintenance.run(cache)

      assert %{climber: %{sample_hits: 30, sample_misses: 10, window_max: 10}} =
               Theine.Maintenance.info(cache)

      # 960 more new keys complete the sample at a hit rate of 3%, no worse
      # than the initial 0, so the first step shrinks the window by 6.
      for key <- 11..970, do: :ok = Theine.put(cache, key, key)
      :ok = Theine.Maintenance.run(cache)

      assert %{
               climber: %{
                 adaptive: true,
                 window_max: 4,
                 protected_max: 78,
                 sample_hits: 0,
                 sample_misses: 0
               }
             } = Theine.Maintenance.info(cache)
    end

    test "adaptive: false leaves every existing policy test result unchanged", %{table: table} do
      # The same traces replayed with a fixed window, once with a climb after
      # every 32 requests and once with none, end in the same tables,
      # weights, limits, evictions and hits; the adaptive policy does not.
      for trace <- [recency_trace(), zipf_trace()] do
        static = bounded(200, adaptive: false)
        climbed = replay_trace(static, table, trace, climb: true)
        plain = replay_trace(static, table, trace, climb: false)
        assert climbed == plain

        adaptive = replay_trace(bounded(200), table, trace, climb: true)
        refute adaptive == plain
      end
    end

    test "the climber grows the window on a recency trace and shrinks it on a frequency trace",
         %{table: table} do
      # Recency: every read is of a key written at most 300 requests ago, so
      # a 1% window (2 entries) turns most of them away at admission.
      trace = recency_trace()
      static = replay_trace(bounded(200, adaptive: false), table, trace, climb: true)
      adaptive = replay_trace(bounded(200), table, trace, climb: true)
      assert static.window_max == 2
      assert adaptive.window_max >= 100
      assert adaptive.hit_rate >= static.hit_rate + 0.10

      # Frequency: a fixed Zipf distribution, where a small window is best.
      trace = zipf_trace()
      static = replay_trace(bounded(200, adaptive: false), table, trace, climb: true)
      wide = replay_trace(bounded(200, window_percent: 40), table, trace, climb: true)
      assert wide.window_max <= 40
      assert wide.hit_rate >= static.hit_rate - 0.01
    end
  end

  # Each new key is followed by three reads of keys written within the last
  # 300 (fixed seed): recency is everything and frequency nothing.
  defp recency_trace do
    :rand.seed(:exsss, {7, 7, 7})

    Enum.flat_map(1..25_000, fn i ->
      [i | for(_ <- 1..3, i > 300, do: i - :rand.uniform(300))]
    end)
  end

  # 100_000 requests, Zipf(0.9) over 5_000 keys (fixed seed), by inverse CDF.
  defp zipf_trace do
    :rand.seed(:exsss, {7, 7, 8})
    weights = for k <- 1..5_000, do: 1 / :math.pow(k, 0.9)
    total = Enum.sum(weights)
    cdf = weights |> Enum.scan(&(&1 + &2)) |> Enum.map(&(&1 / total)) |> List.to_tuple()
    for _ <- 1..100_000, do: search(cdf, :rand.uniform(), 0, tuple_size(cdf) - 1) + 1
  end

  defp search(_cdf, _u, lo, hi) when lo >= hi, do: lo

  defp search(cdf, u, lo, hi) do
    mid = div(lo + hi, 2)
    if elem(cdf, mid) < u, do: search(cdf, u, mid + 1, hi), else: search(cdf, u, lo, mid)
  end

  # Replays `trace` as a cache would see it from an empty start: a key in the
  # entries table is a hit and its read is drained at once, any other is a
  # put that evicts what it displaced. Every 32 requests the pass's sketch
  # aging and, with `climb: true`, its adaptive step run. Returns what the
  # replay left behind.
  defp replay_trace(policy, table, trace, climb: climb?) do
    policy = Policy.reset(policy)
    :ets.delete_all_objects(table)
    :rand.seed(:exsss, {1, 2, 3})
    evictions = evictions(policy)

    {policy, _id, hits, _n} =
      Enum.reduce(trace, {policy, 0, 0, 0}, fn key, {policy, id, hits, n} ->
        {policy, id, hits} =
          case :ets.lookup(table, key) do
            [{^key, _, key_id, _, _, _}] ->
              {Policy.on_access(policy, key_id), id, hits + 1}

            [] ->
              {_status, _evicted, policy} = policy |> put(table, key, id + 1) |> Policy.evict()
              {policy, id + 1, hits}
          end

        policy =
          cond do
            rem(n + 1, 32) != 0 -> policy
            climb? -> policy |> age() |> Policy.climb()
            true -> age(policy)
          end

        {policy, id, hits, n + 1}
      end)

    # `reset/1` does not rewind `seq`, so the order is compared as keys per
    # segment, LRU first.
    %{
      order: for({{segment, _seq}, key} <- Policy.order_rows(policy), do: {segment, key}),
      weights: Policy.weights(policy),
      window_max: policy.window_max,
      protected_max: policy.protected_max,
      evictions: evictions(policy) - evictions,
      hit_rate: hits / length(trace)
    }
  end

  # A write followed by the eviction step and the sketch aging the
  # maintenance pass would run (specs/04 §The pass steps 5 and 6).
  defp write(policy, table, key, id) do
    {_status, _evicted, policy} = policy |> put(table, key, id) |> Policy.evict()
    age(policy)
  end

  defp age(%{sketch: sketch, sketch_size: size, max_size: max_size} = policy) do
    if size >= Sketch.sample_size(max_size) do
      odd = Sketch.reset(sketch)
      %{policy | sketch_size: Sketch.size_after_reset(size, odd)}
    else
      policy
    end
  end

  # Moves a row into `segment` at its MRU end by hand, standing in for the
  # window overflow and the promotions that would otherwise take a longer
  # event sequence to arrange.
  defp place(policy, key, segment) do
    {:ok, {^key, _id, from, seq, weight, _}} = Policy.lookup(policy, key)
    new_seq = policy.next_seq
    true = :ets.delete(policy.order, Policy.order_key(from, seq))
    true = :ets.insert(policy.order, {Policy.order_key(segment, new_seq), key})
    true = :ets.update_element(policy.policy, key, [{3, segment}, {4, new_seq}])

    policy
    |> adjust(from, -weight)
    |> adjust(segment, weight)
    |> Map.put(:next_seq, new_seq + 1)
  end

  defp adjust(policy, :window, delta), do: %{policy | window_weight: policy.window_weight + delta}

  defp adjust(policy, :probation, delta),
    do: %{policy | probation_weight: policy.probation_weight + delta}

  defp adjust(policy, :protected, delta),
    do: %{policy | protected_weight: policy.protected_weight + delta}

  test "on_write of an unknown key adds a row and an ids row", %{policy: policy, sizes: sizes} do
    policy = Policy.on_write(policy, :a, 1, 3, :infinity)

    assert Policy.lookup(policy, :a) == {:ok, {:a, 1, nil, 1, 3, :infinity}}
    assert Policy.count(policy) == 1
    assert Policy.id_count(policy) == 1
    assert Policy.size(sizes) == 1
    assert Policy.weighted_size(sizes) == 3
  end

  test "on_write with a different id replaces the ids row and updates the row", %{
    policy: policy,
    sizes: sizes,
    table: table
  } do
    :ets.insert(table, entry(:a, 2))
    policy = Policy.on_write(policy, :a, 1, 3, :infinity)
    policy = Policy.on_write(policy, :a, 2, 5, 1_000)

    assert Policy.lookup(policy, :a) == {:ok, {:a, 2, nil, 1, 5, 1_000}}
    assert Policy.count(policy) == 1
    assert Policy.id_count(policy) == 1
    assert Policy.size(sizes) == 1
    assert Policy.weighted_size(sizes) == 5
    # The old id is no longer known and the key is live: removing by it is ignored.
    policy = Policy.on_remove(policy, :a, 1)
    assert Policy.count(policy) == 1
  end

  test "on_write with the same id updates weight and expires_at only", %{
    policy: policy,
    sizes: sizes
  } do
    policy = Policy.on_write(policy, :a, 1, 3, :infinity)
    policy = Policy.on_write(policy, :b, 2, 1, :infinity)
    policy = Policy.on_write(policy, :a, 1, 4, 2_000)

    assert Policy.lookup(policy, :a) == {:ok, {:a, 1, nil, 1, 4, 2_000}}
    assert Policy.id_count(policy) == 2
    assert Policy.weighted_size(sizes) == 5
  end

  test "on_remove with the current id deletes both rows", %{policy: policy, sizes: sizes} do
    policy = Policy.on_write(policy, :a, 1, 3, :infinity)
    policy = Policy.on_remove(policy, :a, 1)

    assert Policy.lookup(policy, :a) == :error
    assert Policy.count(policy) == 0
    assert Policy.id_count(policy) == 0
    assert Policy.size(sizes) == 0
    assert Policy.weighted_size(sizes) == 0
  end

  test "on_remove with a stale id is ignored while the entries table holds the key", %{
    policy: policy,
    sizes: sizes,
    table: table
  } do
    :ets.insert(table, entry(:a, 2))
    policy = Policy.on_write(policy, :a, 2, 3, :infinity)
    policy = Policy.on_remove(policy, :a, 1)
    policy = Policy.on_remove(policy, :a, 3)
    policy = Policy.on_remove(policy, :b, 2)

    assert Policy.lookup(policy, :a) == {:ok, {:a, 2, nil, 1, 3, :infinity}}
    assert Policy.id_count(policy) == 1
    assert Policy.size(sizes) == 1
    assert Policy.weighted_size(sizes) == 3
  end

  test "on_remove with a stale id drops the row when the entries table lacks the key", %{
    policy: policy,
    sizes: sizes,
    table: table
  } do
    # The race of specs/05 §Decisions (M1.5): the table kept id 1, the
    # policy applied id 2 last. delete/2 then sends {:removed, :a, 1}.
    :ets.insert(table, entry(:a, 1))
    policy = Policy.on_write(policy, :a, 1, 3, :infinity)
    policy = Policy.on_write(policy, :a, 2, 4, :infinity)
    policy = Policy.on_write(policy, :b, 3, 1, :infinity)
    :ets.delete(table, :a)

    policy = Policy.on_remove(policy, :a, 1)

    assert Policy.lookup(policy, :a) == :error
    assert Policy.count(policy) == 1
    assert Policy.id_count(policy) == 1
    assert Policy.size(sizes) == 1
    assert Policy.weighted_size(sizes) == 1
    # And a removal for a key the policy never had still does nothing.
    policy = Policy.on_remove(policy, :a, 2)
    assert Policy.count(policy) == 1
  end

  test "reset/1 empties the tables and zeroes the sizes", %{policy: policy, sizes: sizes} do
    policy = Policy.on_write(policy, :a, 1, 3, :infinity)
    policy = Policy.reset(policy)

    assert Policy.count(policy) == 0
    assert Policy.id_count(policy) == 0
    assert Policy.size(sizes) == 0
    assert Policy.weighted_size(sizes) == 0
  end

  # An event stream as the maintenance process would see it: ids are unique
  # and increasing (a fresh id per write), removals name any id ever issued.
  # A `:put` inserts into the entries table and reaches the policy; a
  # `:racy_put` reaches the policy only, standing for the write whose event
  # the policy applied last while the table kept another version (specs/05
  # §Decisions M1.5). A `:removed` deletes the table's version when it names
  # it, as `delete/2` and the expired read do, then reaches the policy.
  # With `:access` and `:overflow` in `kinds`, an `:access` names any id ever
  # issued, as a drained read-buffer slot does, and an `:overflow` moves a
  # window key to the probation MRU as evict/1's step 1 will (M2.6).
  @write_kinds [{3, :put}, {1, :racy_put}, {2, :removed}]
  @access_kinds [{3, :put}, {1, :racy_put}, {2, :removed}, {4, :access}, {2, :overflow}]
  @evict_kinds [{3, :put}, {1, :racy_put}, {2, :removed}, {4, :access}, {3, :evict}]
  @resize_kinds @evict_kinds ++ [{3, :resize}]

  defp events(kinds \\ @write_kinds) do
    gen all keys <- list_of(member_of(1..6), min_length: 1, max_length: 40),
            kinds <- list_of(frequency(kinds), length: length(keys)),
            weights <- list_of(integer(1..9), length: length(keys)),
            picks <- list_of(integer(0..length(keys)), length: length(keys)) do
      Enum.zip([Enum.with_index(keys, 1), kinds, weights, picks])
      |> Enum.map(fn
        {{key, id}, :put, weight, _} -> {:put, key, id, weight, :infinity}
        {{key, id}, :racy_put, weight, _} -> {:racy_put, key, id, weight, :infinity}
        {{key, _id}, :removed, _, stale} -> {:removed, key, stale}
        {{_key, _id}, :access, _, pick} -> {:access, pick}
        {{key, _id}, :overflow, _, _} -> {:overflow, key}
        {{_key, _id}, :evict, _, _} -> :evict
        {{_key, _id}, :resize, weight, _} -> {:resize, 2 * (weight - 5)}
      end)
    end
  end

  property "bounded: the invariant holds after every write, access, overflow and removal",
           %{table: table} do
    # max_size 20: window_max 1, protected_max 15. Weights of 1..9 across
    # six keys overflow both freely (specs/05 §Acceptance invariant).
    policy = bounded(20)

    check all events <- events(@access_kinds) do
      policy = Policy.reset(policy)
      :ets.delete_all_objects(table)

      Enum.reduce(events, {policy, %{}}, fn event, {policy, model} ->
        expected = expected_access(policy, model, event)
        {policy, model} = apply_event(policy, table, event, model)
        assert_invariant(policy, model)
        assert_access(policy, expected)
        {policy, model}
      end)
    end
  end

  property "bounded: evict/1 keeps the invariant, bounds the weight and removes what it evicts",
           %{table: table} do
    # max_size 20 with weights up to 9 and evict_batch 2: most evict calls
    # stop at the cap and carry candidates into the next, and writes,
    # accesses and removals land between them (specs/05 §Acceptance
    # Bounded, §Decisions M2.6).
    policy = bounded(20, evict_batch: 2)

    check all events <- events(@evict_kinds), max_runs: 1000 do
      policy = Policy.reset(policy)
      :ets.delete_all_objects(table)

      Enum.reduce(events, {policy, %{}}, fn event, {policy, model} ->
        {policy, model} = apply_event(policy, table, event, model)
        assert_invariant(policy, model)
        {policy, model}
      end)
    end
  end

  property "window and probation weights stay consistent across a resize", %{table: table} do
    # The evict property's events with window resizes of -8..8 between
    # them (specs/05 §Adaptive window): every event keeps the invariant, and
    # a resize moves the limits by exactly the weight it transferred.
    policy = bounded(20, evict_batch: 2)

    check all events <- events(@resize_kinds), max_runs: 1000 do
      policy = Policy.reset(policy)
      :ets.delete_all_objects(table)

      Enum.reduce(events, {policy, %{}}, fn event, {policy, model} ->
        {policy, model} = apply_event(policy, table, event, model)
        assert_invariant(policy, model)
        {policy, model}
      end)
    end
  end

  # What a current-id access must leave behind: the key at the MRU of its
  # new segment, one more sketch count and increment. Stale and unknown ids
  # must leave the sketch alone.
  defp expected_access(policy, model, {:access, id}) do
    before = {Policy.weights(policy), policy.sketch_size, Policy.order_rows(policy)}

    case Enum.find(model, fn {_key, {i, _weight}} -> i == id end) do
      {key, {^id, weight}} ->
        {:ok, {^key, ^id, segment, _seq, ^weight, _}} = Policy.lookup(policy, key)

        segment =
          case segment do
            :probation when weight <= policy.protected_max -> :protected
            :probation -> :probation
            other -> other
          end

        {:current, key, segment, Sketch.frequency(policy.sketch, key), policy.sketch_size}

      nil ->
        {:stale, before}
    end
  end

  defp expected_access(_policy, _model, _event), do: nil

  defp assert_access(_policy, nil), do: :ok

  defp assert_access(policy, {:current, key, segment, frequency, sketch_size}) do
    assert Policy.mru(policy, segment) == {:ok, key}
    assert Sketch.frequency(policy.sketch, key) == min(frequency + 1, 15)
    assert policy.sketch_size == sketch_size + 1
  end

  defp assert_access(policy, {:stale, before}) do
    assert {Policy.weights(policy), policy.sketch_size, Policy.order_rows(policy)} == before
  end

  defp assert_invariant(policy, model) do
    assert_model(policy, model, :any)
    rows = for {key, _} <- model, {:ok, row} = Policy.lookup(policy, key), do: row
    order = Policy.order_rows(policy)
    assert length(order) == map_size(model)

    for {key, _id, segment, seq, _weight, _} <- rows do
      assert segment in [:window, :probation, :protected]
      order_key = Policy.order_key(segment, seq)
      assert :ets.lookup(policy.order, order_key) == [{order_key, key}]
    end

    sums =
      Enum.reduce(rows, %{window: 0, probation: 0, protected: 0}, fn
        {_, _, segment, _, weight, _}, acc -> Map.update!(acc, segment, &(&1 + weight))
      end)

    assert Policy.weights(policy) == sums
    assert policy.protected_weight <= policy.protected_max
  end

  property "after any event sequence the rows, ids and sizes agree with a model", %{
    policy: policy,
    table: table
  } do
    check all events <- events() do
      policy = Policy.reset(policy)
      {policy, model} = replay(policy, table, events)
      assert_model(policy, model, nil)
    end
  end

  property "bounded: every key has one order row and one ids row and the segment weights add up",
           %{table: table} do
    # Writes and removals only, so every key stays in the window and the
    # window weight is the weighted size; weights up to 9 against a bound
    # of 20 overflow it freely, as they may between passes (specs/03 slack).
    policy = bounded(20)

    check all events <- events() do
      policy = Policy.reset(policy)
      {policy, model} = replay(policy, table, events)
      assert_model(policy, model, :window)

      order = Policy.order_rows(policy)
      assert length(order) == map_size(model)
      assert order |> Enum.map(&elem(&1, 1)) |> Enum.sort() == model |> Map.keys() |> Enum.sort()

      assert Enum.all?(order, fn {{segment, seq}, _} ->
               segment == :window and seq < policy.next_seq
             end)

      weighted = model |> Map.values() |> Enum.sum_by(&elem(&1, 1))
      assert Policy.weights(policy) == %{window: weighted, probation: 0, protected: 0}

      # The sketch never under-counts: every key ever written reads >= 1,
      # and the increments are one per new key or new id.
      written = for {kind, key, _, _, _} <- events, kind in [:put, :racy_put], uniq: true, do: key
      assert Enum.all?(written, &(Sketch.frequency(policy.sketch, &1) >= 1))
      assert policy.sketch_size == Enum.count(events, &(elem(&1, 0) in [:put, :racy_put]))
    end
  end

  defp replay(policy, table, events) do
    :ets.delete_all_objects(table)

    Enum.reduce(events, {policy, %{}}, fn event, {policy, model} ->
      apply_event(policy, table, event, model)
    end)
  end

  # Applies one event to the policy and to the model, a map of the keys the
  # policy must hold to `{id, weight}`.
  defp apply_event(policy, table, {:put, key, id, weight, expires_at}, model) do
    :ets.insert(table, entry(key, id, weight))
    {Policy.on_write(policy, key, id, weight, expires_at), Map.put(model, key, {id, weight})}
  end

  defp apply_event(policy, _table, {:racy_put, key, id, weight, expires_at}, model) do
    {Policy.on_write(policy, key, id, weight, expires_at), Map.put(model, key, {id, weight})}
  end

  defp apply_event(policy, table, {:removed, key, id}, model) do
    case :ets.lookup(table, key) do
      [{^key, _, ^id, _, _, _} = version] -> :ets.delete_object(table, version)
      _ -> :ok
    end

    model =
      case model do
        %{^key => {^id, _}} ->
          Map.delete(model, key)

        %{^key => _} ->
          if :ets.member(table, key), do: model, else: Map.delete(model, key)

        _ ->
          model
      end

    {Policy.on_remove(policy, key, id), model}
  end

  defp apply_event(policy, _table, {:access, id}, model) do
    {Policy.on_access(policy, id), model}
  end

  defp apply_event(policy, _table, {:overflow, key}, model) do
    case Policy.lookup(policy, key) do
      {:ok, {^key, _, :window, _, _, _}} -> {place(policy, key, :probation), model}
      _ -> {policy, model}
    end
  end

  # One eviction step: the entries it reports evicted left the table, a
  # key it dropped never keeps the policy's version in the table, the
  # window fits after it, and the weight fits once it says :done.
  defp apply_event(policy, table, :evict, model) do
    before = evictions(policy)
    {status, evicted, policy} = Policy.evict(policy)

    assert evicted == evictions(policy) - before
    assert evicted <= policy.evict_batch
    assert policy.window_weight <= policy.window_max
    if status == :done, do: assert(total(policy) <= policy.max_size)
    if status == :more, do: assert(total(policy) > policy.max_size)

    gone = for {key, {id, _weight}} <- model, Policy.lookup(policy, key) == :error, do: {key, id}
    assert evicted <= length(gone)

    for {key, id} <- gone do
      refute match?([{^key, _, ^id, _, _, _}], :ets.lookup(table, key))
    end

    {policy, Map.drop(model, Enum.map(gone, &elem(&1, 0)))}
  end

  # One resize: no key leaves or changes, the total and the region sum stay,
  # the window's excess over its limit (puts not yet evicted) stays, the
  # window limit stays at least 1, and the untransferred rest is kept with
  # the requested sign.
  defp apply_event(policy, _table, {:resize, amount}, model) do
    before = Policy.weights(policy)
    resized = Policy.resize(policy, amount)
    after_ = Policy.weights(resized)
    moved = after_.window - before.window

    assert Policy.count(resized) == Policy.count(policy)
    assert total(resized) == total(policy)
    assert resized.window_max >= 1
    assert resized.protected_max >= 0
    assert resized.window_max + resized.protected_max == policy.window_max + policy.protected_max
    assert resized.window_max - policy.window_max == moved
    assert resized.window_weight - resized.window_max == policy.window_weight - policy.window_max
    assert abs(moved) <= abs(amount)

    left = resized.climber.adjustment
    assert left == 0 or (left > 0 and amount > 0) or (left < 0 and amount < 0)
    assert abs(left) <= abs(amount)

    {resized, model}
  end

  defp assert_model(policy, model, segment) do
    assert Policy.count(policy) == map_size(model)
    assert Policy.id_count(policy) == map_size(model)
    assert Policy.size(policy.sizes) == map_size(model)

    assert Policy.weighted_size(policy.sizes) ==
             model |> Map.values() |> Enum.sum_by(&elem(&1, 1))

    for {key, {id, weight}} <- model do
      assert {:ok, {^key, ^id, found, _seq, ^weight, :infinity}} = Policy.lookup(policy, key)
      assert segment == :any or found == segment
    end
  end
end
