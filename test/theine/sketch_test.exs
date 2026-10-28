defmodule Theine.SketchTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Theine.Sketch

  doctest Sketch

  # Checked-in layout vectors (specs/02 §Hashing, §Acceptance): the 0-based
  # word index and the bit offset of each of a key's four counters. The
  # table is the layout's regression guard; if a hashing change is intended,
  # regenerate it with `Sketch.positions/2` and say so in specs/02 §Decisions.
  @vectors %{
    1 => [
      {:a, [{1, 40}, {2, 20}, {4, 60}, {6, 36}]},
      {:b, [{0, 48}, {3, 24}, {4, 56}, {7, 44}]},
      {:zzz, [{0, 48}, {3, 12}, {5, 44}, {7, 4}]},
      {"", [{0, 4}, {3, 16}, {5, 20}, {6, 48}]},
      {"key", [{0, 36}, {2, 60}, {4, 32}, {7, 32}]},
      {"key-1", [{1, 20}, {2, 44}, {5, 20}, {6, 60}]},
      {0, [{1, 60}, {2, 4}, {5, 12}, {7, 32}]},
      {1, [{1, 44}, {2, 0}, {5, 44}, {7, 0}]},
      {42, [{1, 12}, {3, 56}, {4, 52}, {7, 4}]},
      {-7, [{0, 60}, {2, 8}, {4, 32}, {6, 24}]},
      {1_099_511_627_776, [{0, 0}, {2, 60}, {5, 0}, {6, 40}]},
      {{:user, 7}, [{0, 16}, {2, 36}, {5, 32}, {6, 36}]},
      {[1, 2, 3], [{0, 4}, {2, 24}, {4, 40}, {7, 48}]},
      {3.5, [{1, 52}, {3, 16}, {5, 8}, {6, 36}]},
      {nil, [{1, 12}, {2, 36}, {5, 24}, {6, 52}]}
    ],
    1_000 => [
      {:a, [{193, 40}, {194, 20}, {196, 60}, {198, 36}]},
      {:b, [{872, 48}, {875, 24}, {876, 56}, {879, 44}]},
      {:zzz, [{8, 48}, {11, 12}, {13, 44}, {15, 4}]},
      {"", [{312, 4}, {315, 16}, {317, 20}, {318, 48}]},
      {"key", [{672, 36}, {674, 60}, {676, 32}, {679, 32}]},
      {"key-1", [{49, 20}, {50, 44}, {53, 20}, {54, 60}]},
      {0, [{569, 60}, {570, 4}, {573, 12}, {575, 32}]},
      {1, [{9, 44}, {10, 0}, {13, 44}, {15, 0}]},
      {42, [{753, 12}, {755, 56}, {756, 52}, {759, 4}]},
      {-7, [{696, 60}, {698, 8}, {700, 32}, {702, 24}]},
      {1_099_511_627_776, [{680, 0}, {682, 60}, {685, 0}, {686, 40}]},
      {{:user, 7}, [{912, 16}, {914, 36}, {917, 32}, {918, 36}]},
      {[1, 2, 3], [{624, 4}, {626, 24}, {628, 40}, {631, 48}]},
      {3.5, [{1009, 52}, {1011, 16}, {1013, 8}, {1014, 36}]},
      {nil, [{857, 12}, {858, 36}, {861, 24}, {862, 52}]}
    ],
    10_000 => [
      {:a, [{15553, 40}, {15554, 20}, {15556, 60}, {15558, 36}]},
      {:b, [{5992, 48}, {5995, 24}, {5996, 56}, {5999, 44}]},
      {:zzz, [{1032, 48}, {1035, 12}, {1037, 44}, {1039, 4}]},
      {"", [{8504, 4}, {8507, 16}, {8509, 20}, {8510, 48}]},
      {"key", [{10912, 36}, {10914, 60}, {10916, 32}, {10919, 32}]},
      {"key-1", [{7217, 20}, {7218, 44}, {7221, 20}, {7222, 60}]},
      {0, [{569, 60}, {570, 4}, {573, 12}, {575, 32}]},
      {1, [{6153, 44}, {6154, 0}, {6157, 44}, {6159, 0}]},
      {42, [{13041, 12}, {13043, 56}, {13044, 52}, {13047, 4}]},
      {-7, [{1720, 60}, {1722, 8}, {1724, 32}, {1726, 24}]},
      {1_099_511_627_776, [{11944, 0}, {11946, 60}, {11949, 0}, {11950, 40}]},
      {{:user, 7}, [{3984, 16}, {3986, 36}, {3989, 32}, {3990, 36}]},
      {[1, 2, 3], [{11888, 4}, {11890, 24}, {11892, 40}, {11895, 48}]},
      {3.5, [{6129, 52}, {6131, 16}, {6133, 8}, {6134, 36}]},
      {nil, [{16217, 12}, {16218, 36}, {16221, 24}, {16222, 52}]}
    ]
  }

  defp key_gen do
    one_of([integer(), binary(), atom(:alphanumeric), tuple({atom(:alphanumeric), integer()})])
  end

  describe "layout" do
    test "words/1 is max(8, next_power_of_two(max_size)) capped at 2^30" do
      assert Sketch.words(1) == 8
      assert Sketch.words(8) == 8
      assert Sketch.words(9) == 16
      assert Sketch.words(1_000) == 1024
      assert Sketch.words(1_024) == 1024
      assert Sketch.words(1_025) == 2048
      assert Sketch.words(1_000_000) == 1 <<< 20
      assert Sketch.words(1 <<< 30) == 1 <<< 30
      assert Sketch.words((1 <<< 30) + 1) == 1 <<< 30
      assert Sketch.words(1 <<< 62) == 1 <<< 30
    end

    test "new/1 allocates words unsigned words in blocks of 8" do
      sketch = Sketch.new(1_000)

      assert sketch.words == 1024
      assert sketch.block_mask == 127
      assert %{size: 1024, min: 0, max: max} = :atomics.info(sketch.ref)
      assert max == (1 <<< 64) - 1
      assert Sketch.dump(sketch) == List.duplicate(0, 1024)
    end

    test "layout vectors match the checked-in table" do
      for {max_size, vectors} <- @vectors, {key, expected} <- vectors do
        sketch = Sketch.new(max_size)

        assert Sketch.positions(sketch, key) == expected,
               "positions of #{inspect(key)} at max_size #{max_size} changed"
      end
    end

    property "a key's four counters sit in the four word pairs of one block" do
      check all key <- key_gen(), max_size <- integer(1..100_000) do
        sketch = Sketch.new(max_size)
        positions = Sketch.positions(sketch, key)
        [{index0, _} | _] = positions
        block = index0 - rem(index0, 8)

        assert block + 8 <= sketch.words

        for {{index, offset}, i} <- Enum.with_index(positions) do
          assert (index - block) in [2 * i, 2 * i + 1]
          assert offset in 0..60//4
        end
      end
    end

    test "the same key has the same in-block position at every size" do
      for {key, expected} <- @vectors[1], max_size <- [1_000, 10_000] do
        positions = Sketch.positions(Sketch.new(max_size), key)
        assert Enum.map(positions, fn {index, offset} -> {rem(index, 8), offset} end) == expected
      end
    end
  end

  describe "increment/2 and frequency/2" do
    test "frequency of a never-seen key is 0" do
      sketch = Sketch.new(100)
      assert Sketch.frequency(sketch, :never) == 0
      assert Sketch.frequency(sketch, "never") == 0
    end

    property "frequency equals min(n, 15) after n increments of one key" do
      check all key <- key_gen(), n <- integer(0..40), max_size <- integer(1..5_000) do
        sketch = Sketch.new(max_size)
        for _ <- 1..n//1, do: Sketch.increment(sketch, key)

        assert Sketch.frequency(sketch, key) == min(n, 15)
      end
    end

    property "frequency never under-estimates the true count before saturation" do
      check all keys <- list_of(key_gen(), max_length: 400), max_size <- integer(1..2_000) do
        sketch = Sketch.new(max_size)
        Enum.each(keys, &Sketch.increment(sketch, &1))

        for {key, count} <- Enum.frequencies(keys) do
          assert Sketch.frequency(sketch, key) >= min(count, 15)
        end
      end
    end

    test "saturated counters stop incrementing and the words stay in range" do
      sketch = Sketch.new(1)
      for _ <- 1..100, do: Sketch.increment(sketch, :hot)

      assert Sketch.frequency(sketch, :hot) == 15

      for {index, offset} <- Sketch.positions(sketch, :hot) do
        assert (:atomics.get(sketch.ref, index + 1) >>> offset &&& 0xF) == 15
      end
    end

    test "collision quality: 100_000 single-hit keys at max_size 10_000" do
      # specs/02 §Acceptance and §Decisions M2.1: independent uniform
      # counters predict 99.85% at <= 3 and 62% at <= 1 for this load.
      sketch = Sketch.new(10_000)
      keys = for i <- 1..100_000, do: {:k, i}
      Enum.each(keys, &Sketch.increment(sketch, &1))
      frequencies = Enum.map(keys, &Sketch.frequency(sketch, &1))

      assert Enum.all?(frequencies, &(&1 >= 1))
      assert Enum.count(frequencies, &(&1 <= 3)) >= 99_000
      assert Enum.count(frequencies, &(&1 <= 1)) >= 55_000
    end
  end

  describe "clear/1" do
    test "zeroes every nibble" do
      sketch = Sketch.new(500)
      keys = for i <- 1..2_000, do: "k#{i}"
      for key <- keys, _ <- 1..3, do: Sketch.increment(sketch, key)

      assert Enum.any?(Sketch.dump(sketch), &(&1 != 0))
      assert Sketch.frequency(sketch, "k1") >= 3

      assert Sketch.clear(sketch) == :ok

      assert Sketch.dump(sketch) == List.duplicate(0, sketch.words)
      assert Enum.all?(keys, &(Sketch.frequency(sketch, &1) == 0))
    end
  end
end
