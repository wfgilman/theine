defmodule Theine.ConfigTest do
  use ExUnit.Case, async: true

  alias Theine.Config

  doctest Theine.Config

  @required [name: :config_test, max_size: :infinity]

  test "every option in the specs/08 table has its documented default" do
    config = Config.new!(@required)

    assert config.weigher == nil
    assert config.expire_after_write == :infinity
    assert config.refresh_after_write == :infinity
    assert config.loader == nil
    assert config.window_percent == 1
    assert config.adaptive == true
    assert config.stripes == Config.default_stripes()
    assert config.stripes >= System.schedulers_online()
    assert config.stripes < 2 * System.schedulers_online()
    assert Config.power_of_two?(config.stripes)
    assert config.read_buffer_slots == 64
    assert config.drain_threshold == 32
    assert config.write_hwm == 1024
    assert config.write_batch == 256
    assert config.expire_batch == 1024
    assert config.evict_batch == 1024
    assert config.maintenance_interval == 1000
    assert config.drain_backoff == 3
    assert config.stats == true
    assert config.test_hooks == false
    assert config.policy_module == Theine.Policy
  end

  test "policy_module is accepted with test_hooks only" do
    opts = Keyword.merge(@required, policy_module: Theine.Test.Policy)
    assert Config.new!(opts ++ [test_hooks: true]).policy_module == Theine.Test.Policy
    assert Config.new!(Keyword.put(@required, :policy_module, Theine.Policy)).test_hooks == false

    assert_raise ArgumentError, ~r/:policy_module.*test_hooks: true/, fn -> Config.new!(opts) end
  end

  test "names the table, the maintenance process and the task supervisor after the cache" do
    config = Config.new!(@required)

    assert config.table == :config_test
    assert config.maintenance == :"Elixir.Theine.Maintenance.config_test"
    assert config.task_supervisor == :"Elixir.Theine.TaskSupervisor.config_test"
    assert config.inflight == :"Elixir.Theine.Loader.Inflight.config_test"
    assert config.waiters == :"Elixir.Theine.Loader.Waiters.config_test"
    assert Enum.all?([config.ids, config.pending, config.flags, config.counters], &is_nil/1)
  end

  test "every option is accepted with a valid value" do
    weigher = fn _k, _v -> 2 end
    loader = fn _k -> {:ignore, nil} end

    config =
      Config.new!(
        name: :full,
        max_size: :infinity,
        weigher: weigher,
        expire_after_write: 10,
        refresh_after_write: 5,
        loader: loader,
        window_percent: 80,
        adaptive: true,
        stripes: 4,
        read_buffer_slots: 16,
        drain_threshold: 8,
        write_hwm: 2,
        write_batch: 4,
        expire_batch: 5,
        evict_batch: 6,
        maintenance_interval: 50,
        drain_backoff: 0,
        stats: false,
        test_hooks: true,
        policy_module: Theine.Test.Policy
      )

    assert config.weigher == weigher
    assert config.loader == loader
    assert config.expire_after_write == 10
    assert config.refresh_after_write == 5
    assert config.window_percent == 80
    assert config.adaptive
    assert config.stripes == 4
    assert config.read_buffer_slots == 16
    assert config.drain_threshold == 8
    assert config.write_hwm == 2
    assert config.write_batch == 4
    assert config.expire_batch == 5
    assert config.evict_batch == 6
    assert config.maintenance_interval == 50
    assert config.drain_backoff == 0
    refute config.stats
    assert config.test_hooks
    assert config.policy_module == Theine.Test.Policy
  end

  test "missing name or max_size raises naming the option" do
    assert_raise ArgumentError, ~r/:name/, fn -> Config.new!(max_size: :infinity) end
    assert_raise ArgumentError, ~r/:max_size/, fn -> Config.new!(name: :x) end
  end

  test "max_size accepts a positive integer or :infinity" do
    assert Config.new!(name: :x, max_size: 100).max_size == 100
    assert Config.new!(name: :x, max_size: 1).max_size == 1
    assert Config.new!(name: :x, max_size: :infinity).max_size == :infinity
  end

  test "every option rejects a value of the wrong type, naming the option" do
    bad = [
      name: "string",
      name: nil,
      max_size: 0,
      max_size: :unbounded,
      weigher: fn _ -> 1 end,
      expire_after_write: 0,
      expire_after_write: :never,
      refresh_after_write: -1,
      loader: fn _, _ -> 1 end,
      window_percent: 0,
      window_percent: 81,
      adaptive: 1,
      stripes: 0,
      stripes: 3,
      read_buffer_slots: 1.5,
      read_buffer_slots: 6,
      drain_threshold: -1,
      drain_threshold: 12,
      write_hwm: 0,
      write_batch: nil,
      expire_batch: :many,
      evict_batch: 0,
      maintenance_interval: 0,
      drain_backoff: -1,
      drain_backoff: 1.5,
      stats: :yes,
      test_hooks: 1,
      policy_module: "Theine.Policy",
      policy_module: nil
    ]

    for {key, value} <- bad do
      opts = Keyword.merge(@required, [{key, value}])

      assert_raise ArgumentError, ~r/#{inspect(key)}/, fn -> Config.new!(opts) end
    end
  end

  test "the read-buffer sizes accept powers of two only, naming the option" do
    for key <- [:stripes, :read_buffer_slots, :drain_threshold] do
      for n <- [1, 2, 4, 64, 1024] do
        assert Map.fetch!(Config.new!(Keyword.put(@required, key, n)), key) == n
      end

      for n <- [3, 6, 12, 100, 1_000] do
        message = ~r/#{inspect(key)}.*#{n}.*power of two/

        assert_raise ArgumentError, message, fn ->
          Config.new!(Keyword.put(@required, key, n))
        end
      end
    end
  end

  test "same_options?/2 ignores the runtime handles" do
    a = Config.new!(@required)
    b = %{a | ids: :atomics.new(1, []), counters: :counters.new(1, [])}
    assert Config.same_options?(a, b)
    refute Config.same_options?(a, %{b | write_hwm: 1})
  end
end
