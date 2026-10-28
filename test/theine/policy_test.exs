defmodule Theine.PolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Theine.{Config, Policy}

  # The entries table the policy consults on a stale removal (specs/05
  # §Events `on_remove`). Named after the config's table, owned by the test
  # process, so it disappears with it; tests in one module run one at a time.
  setup do
    config = %{
      Config.new!(name: :policy_test, max_size: :infinity)
      | sizes: :atomics.new(2, signed: true)
    }

    table = :ets.new(config.table, [:set, :public, :named_table])
    %{policy: Policy.new(config), sizes: config.sizes, table: table}
  end

  defp entry(key, id, weight \\ 1), do: {key, nil, id, weight, 0, :infinity}

  test "new/1 publishes zero sizes", %{sizes: sizes} do
    :atomics.put(sizes, 1, 5)
    policy = Policy.new(%{Config.new!(name: :policy_test, max_size: :infinity) | sizes: sizes})
    assert Policy.size(sizes) == 0
    assert Policy.weighted_size(sizes) == 0
    assert Policy.count(policy) == 0
  end

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
    sizes: sizes,
    table: table
  } do
    check all events <- events() do
      policy = Policy.reset(policy)
      :ets.delete_all_objects(table)

      {policy, model} =
        Enum.reduce(events, {policy, %{}}, fn
          {:put, key, id, weight, expires_at}, {policy, model} ->
            :ets.insert(table, entry(key, id, weight))

            {Policy.on_write(policy, key, id, weight, expires_at),
             Map.put(model, key, {id, weight})}

          {:racy_put, key, id, weight, expires_at}, {policy, model} ->
            {Policy.on_write(policy, key, id, weight, expires_at),
             Map.put(model, key, {id, weight})}

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

      assert Policy.count(policy) == map_size(model)
      assert Policy.id_count(policy) == map_size(model)
      assert Policy.size(sizes) == map_size(model)
      assert Policy.weighted_size(sizes) == model |> Map.values() |> Enum.sum_by(&elem(&1, 1))

      for {key, {id, weight}} <- model do
        assert {:ok, {^key, ^id, nil, _seq, ^weight, :infinity}} = Policy.lookup(policy, key)
      end
    end
  end
end
