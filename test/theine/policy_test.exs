defmodule Theine.PolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Theine.{Config, Policy}

  setup do
    config = %{
      Config.new!(name: :policy_test, max_size: :infinity)
      | sizes: :atomics.new(2, signed: true)
    }

    %{policy: Policy.new(config), sizes: config.sizes}
  end

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
    sizes: sizes
  } do
    policy = Policy.on_write(policy, :a, 1, 3, :infinity)
    policy = Policy.on_write(policy, :a, 2, 5, 1_000)

    assert Policy.lookup(policy, :a) == {:ok, {:a, 2, nil, 1, 5, 1_000}}
    assert Policy.count(policy) == 1
    assert Policy.id_count(policy) == 1
    assert Policy.size(sizes) == 1
    assert Policy.weighted_size(sizes) == 5
    # The old id is no longer known: removing by it is ignored.
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

  test "on_remove with a stale or unknown id is ignored", %{policy: policy, sizes: sizes} do
    policy = Policy.on_write(policy, :a, 2, 3, :infinity)
    policy = Policy.on_remove(policy, :a, 1)
    policy = Policy.on_remove(policy, :b, 2)

    assert Policy.lookup(policy, :a) == {:ok, {:a, 2, nil, 1, 3, :infinity}}
    assert Policy.size(sizes) == 1
    assert Policy.weighted_size(sizes) == 3
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
  defp events do
    gen all keys <- list_of(member_of(1..6), min_length: 1, max_length: 40),
            kinds <- list_of(frequency([{3, :put}, {1, :removed}]), length: length(keys)),
            weights <- list_of(integer(1..9), length: length(keys)),
            removes <- list_of(integer(0..length(keys)), length: length(keys)) do
      Enum.zip([Enum.with_index(keys, 1), kinds, weights, removes])
      |> Enum.map(fn
        {{key, id}, :put, weight, _} -> {:put, key, id, weight, :infinity}
        {{key, _id}, :removed, _, stale} -> {:removed, key, stale}
      end)
    end
  end

  property "after any event sequence the rows, ids and sizes agree with a model", %{
    policy: policy,
    sizes: sizes
  } do
    check all events <- events() do
      policy = Policy.reset(policy)

      {policy, model} =
        Enum.reduce(events, {policy, %{}}, fn
          {:put, key, id, weight, expires_at}, {policy, model} ->
            {Policy.on_write(policy, key, id, weight, expires_at),
             Map.put(model, key, {id, weight})}

          {:removed, key, id}, {policy, model} ->
            model =
              case model do
                %{^key => {^id, _}} -> Map.delete(model, key)
                _ -> model
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
