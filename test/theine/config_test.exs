defmodule Theine.ConfigTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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
    assert config.partitions == 1
    assert config.stats == true
    assert config.eviction_listener == false
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

  test "has one partition by default, whose maintenance name is today's" do
    config = Config.new!(@required)

    assert config.partitions == 1
    assert config.partition == 0
    assert config.maintenances == {config.maintenance}

    assert Config.maintenance_names(:config_test, 4) ==
             {:"Elixir.Theine.Maintenance.config_test",
              :"Elixir.Theine.Maintenance.config_test.Partition1",
              :"Elixir.Theine.Maintenance.config_test.Partition2",
              :"Elixir.Theine.Maintenance.config_test.Partition3"}
  end

  describe "the partitions option (specs/12 §What is asked)" do
    test "takes a power of two from 1 to 64 and names one maintenance process per partition" do
      for n <- [1, 2, 4, 8, 16, 32, 64] do
        config = Config.new!(Keyword.put(@required, :partitions, n))

        assert config.partitions == n
        assert config.maintenances == Config.maintenance_names(:config_test, n)
        assert elem(config.maintenances, 0) == config.maintenance
      end
    end

    test "rejects anything else, naming the option" do
      for n <- [0, -1, 3, 6, 12, 128, 1.0, :four, nil] do
        assert_raise ArgumentError, ~r/:partitions.*power of two from 1 to 64/, fn ->
          Config.new!(Keyword.put(@required, :partitions, n))
        end
      end
    end

    # specs/12 §Settled questions 1. This replaces M8.2's test that a finite
    # max_size took one partition only: M8.4 lifts that restriction.
    test "minimum share" do
      assert Config.min_share() == 10_000
      assert Config.new!(name: :x, max_size: 100, partitions: 1).partitions == 1

      for n <- [2, 4, 8, 64] do
        # div(max_size, n) at the minimum is accepted, one below it is not.
        assert Config.new!(name: :x, max_size: n * 10_000, partitions: n).partitions == n
        assert Config.new!(name: :x, max_size: n * 10_000 + n - 1, partitions: n).partitions == n

        assert_raise ArgumentError,
                     ~r/:partitions \(#{n}\) needs a max_size of at least #{n * 10_000}/,
                     fn -> Config.new!(name: :x, max_size: n * 10_000 - 1, partitions: n) end
      end

      # An unbounded cache has no policy to dilute, so no minimum.
      assert Config.new!(name: :x, max_size: :infinity, partitions: 64).partitions == 64
    end

    property "shares add up to max_size" do
      check all exponent <- integer(0..6),
                extra <- integer(0..1_000_000) do
        n = Integer.pow(2, exponent)
        max_size = n * 10_000 + extra
        shares = for p <- 0..(n - 1), do: Theine.Partition.share(max_size, n, p)

        assert Enum.sum(shares) == max_size
        assert Enum.max(shares) - Enum.min(shares) <= 1
        # The larger shares are the first rem(max_size, n).
        assert shares == Enum.sort(shares, :desc)

        config = Config.new!(name: :x, max_size: max_size, partitions: n)

        assert for(p <- 0..(n - 1), do: Config.partition(config, p).max_size) == shares
      end
    end

    test "partition/2 of an unbounded cache is the stored config with its partition set" do
      config = Config.new!(Keyword.put(@required, :partitions, 4))

      for p <- 0..3 do
        assert Config.partition(config, p) == %{config | partition: p}
      end

      assert_raise FunctionClauseError, fn -> Config.partition(config, 4) end
    end

    test "partition/2 of a bounded cache carries the partition's share and sketch" do
      config = Config.new!(name: :x, max_size: 40_002, partitions: 4)
      sketches = List.to_tuple(for p <- 0..3, do: {:sketch, p})
      config = %{config | sketches: sketches}

      for {p, share} <- [{0, 10_001}, {1, 10_001}, {2, 10_000}, {3, 10_000}] do
        assert Config.partition(config, p) ==
                 %{config | partition: p, max_size: share, sketch: {:sketch, p}}
      end

      # Before the Owner allocated them, the view has no sketch.
      assert Config.partition(%{config | sketches: nil}, 1).sketch == nil

      # A bounded cache of one partition: the stored config itself.
      one = Config.new!(name: :x, max_size: 1_000)
      assert Config.partition(one, 0) == one
    end
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
        partitions: 8,
        stats: false,
        eviction_listener: true,
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
    assert config.partitions == 8
    refute config.stats
    assert config.eviction_listener
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
      partitions: 3,
      stats: :yes,
      eviction_listener: nil,
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
