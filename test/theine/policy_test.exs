defmodule Theine.PolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Theine.{Config, Policy, Sketch}

  doctest Policy

  # The entries table the policy consults on a stale removal (specs/05
  # §Events `on_remove`). Named after the config's table, owned by the test
  # process, so it disappears with it; tests in one module run one at a time.
  setup do
    config = config(:infinity)
    table = :ets.new(config.table, [:set, :public, :named_table])
    %{policy: Policy.new(config), sizes: config.sizes, table: table}
  end

  # A config as Theine.Owner would complete it, without starting a cache:
  # the sizes atomics always, the sketch only under a bound.
  defp config(max_size, opts \\ []) do
    config = Config.new!([name: :policy_test, max_size: max_size] ++ opts)

    %{
      config
      | sizes: :atomics.new(2, signed: true),
        sketch: if(is_integer(max_size), do: Sketch.new(max_size), else: nil)
    }
  end

  defp bounded(max_size, opts \\ []), do: Policy.new(config(max_size, opts))

  defp entry(key, id, weight \\ 1), do: {key, nil, id, weight, 0, :infinity}

  defp keys_in_order(policy, segment) do
    for {{^segment, _seq}, key} <- Policy.order_rows(policy), do: key
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

    test "the sentinel sorts after every live order key" do
      policy = %{bounded(100) | next_seq: Policy.max_seq() - 2}
      policy = Policy.on_write(policy, :a, 1, 1, :infinity)
      policy = Policy.on_write(policy, :b, 2, 1, :infinity)
      assert Policy.mru(policy, :window) == {:ok, :b}
      assert Policy.lru(policy, :window) == {:ok, :a}
    end
  end

  # Moves a row into `segment` at its MRU end by hand, standing in for
  # on_access/2 (M2.5) and evict/1 (M2.6).
  defp place(policy, key, segment) do
    {:ok, {^key, _id, from, seq, weight, _}} = Policy.lookup(policy, key)
    new_seq = policy.next_seq
    true = :ets.delete(policy.order, {from, seq})
    true = :ets.insert(policy.order, {{segment, new_seq}, key})
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
  defp events do
    gen all keys <- list_of(member_of(1..6), min_length: 1, max_length: 40),
            kinds <-
              list_of(frequency([{3, :put}, {1, :racy_put}, {2, :removed}]),
                length: length(keys)
              ),
            weights <- list_of(integer(1..9), length: length(keys)),
            removes <- list_of(integer(0..length(keys)), length: length(keys)) do
      Enum.zip([Enum.with_index(keys, 1), kinds, weights, removes])
      |> Enum.map(fn
        {{key, id}, :put, weight, _} -> {:put, key, id, weight, :infinity}
        {{key, id}, :racy_put, weight, _} -> {:racy_put, key, id, weight, :infinity}
        {{key, _id}, :removed, _, stale} -> {:removed, key, stale}
      end)
    end
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
    # No on_access or evict yet, so every key stays in the window and the
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

    Enum.reduce(events, {policy, %{}}, fn
      {:put, key, id, weight, expires_at}, {policy, model} ->
        :ets.insert(table, entry(key, id, weight))
        {Policy.on_write(policy, key, id, weight, expires_at), Map.put(model, key, {id, weight})}

      {:racy_put, key, id, weight, expires_at}, {policy, model} ->
        {Policy.on_write(policy, key, id, weight, expires_at), Map.put(model, key, {id, weight})}

      {:removed, key, id}, {policy, model} ->
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
    end)
  end

  defp assert_model(policy, model, segment) do
    assert Policy.count(policy) == map_size(model)
    assert Policy.id_count(policy) == map_size(model)
    assert Policy.size(policy.sizes) == map_size(model)

    assert Policy.weighted_size(policy.sizes) ==
             model |> Map.values() |> Enum.sum_by(&elem(&1, 1))

    for {key, {id, weight}} <- model do
      assert {:ok, {^key, ^id, ^segment, _seq, ^weight, :infinity}} = Policy.lookup(policy, key)
    end
  end
end
