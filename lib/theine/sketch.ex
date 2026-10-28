defmodule Theine.Sketch do
  @moduledoc """
  A count-min sketch with 4-bit counters in an `:atomics` array: Caffeine's
  `FrequencySketch` with the same layout and aging rule (specs/02).

  The policy asks it how often a key has been seen lately. Only the
  maintenance process writes to it, during drains, so a word is read and
  updated without compare-exchange (specs/02 §Ownership).

  Layout: `words` 64-bit unsigned words, each holding 16 counters of 4 bits,
  grouped in blocks of 8 words. A key hashes to one block and to one counter
  in each of the block's four word pairs, so its four counters are always in
  four distinct words of the same block (specs/02 §Hashing).

  The struct is immutable metadata around the array; the number of
  increments since the last reset and the reset cursor live in the
  maintenance state (specs/04 §Responsibilities), not here.
  """

  import Bitwise

  @type t :: %__MODULE__{
          ref: :atomics.atomics_ref(),
          words: pos_integer(),
          block_mask: non_neg_integer()
        }

  @enforce_keys [:ref, :words, :block_mask]
  defstruct [:ref, :words, :block_mask]

  @type frequency :: 0..15

  @min_words 8
  @max_words 1 <<< 30
  @mask32 0xFFFFFFFF
  @nibble 0xF

  @doc """
  The number of 64-bit words a sketch for `max_size` uses:
  `max(8, next_power_of_two(max_size))`, capped at 2^30 words (8 GiB) for
  weighted caches whose maximum weight is larger than that (specs/02
  §Layout).

      iex> Theine.Sketch.words(1)
      8
      iex> Theine.Sketch.words(1_000)
      1024
      iex> Theine.Sketch.words(1_024)
      1024
      iex> Theine.Sketch.words(1_025)
      2048
      iex> Theine.Sketch.words(1_099_511_627_776) == 1_073_741_824
      true
  """
  @spec words(pos_integer()) :: pos_integer()
  def words(max_size) when is_integer(max_size) and max_size > 0 do
    max_size |> ceil_pow2(1) |> max(@min_words) |> min(@max_words)
  end

  @doc "Allocates a zeroed sketch sized for `max_size`."
  @spec new(pos_integer()) :: t()
  def new(max_size) do
    words = words(max_size)

    %__MODULE__{
      ref: :atomics.new(words, signed: false),
      words: words,
      block_mask: (words >>> 3) - 1
    }
  end

  @doc """
  Adds one to each of the key's four counters that is below 15 (specs/02
  §Operations). Counting the increment toward the reset is the caller's job.
  """
  @spec increment(t(), term()) :: :ok
  def increment(%__MODULE__{ref: ref, block_mask: block_mask}, key) do
    {block, counter_hash} = hash(key, block_mask)
    increment_at(ref, slot(block, counter_hash, 0))
    increment_at(ref, slot(block, counter_hash, 1))
    increment_at(ref, slot(block, counter_hash, 2))
    increment_at(ref, slot(block, counter_hash, 3))
  end

  @doc "The estimated frequency of `key`: the minimum of its four counters."
  @spec frequency(t(), term()) :: frequency()
  def frequency(%__MODULE__{ref: ref, block_mask: block_mask}, key) do
    {block, counter_hash} = hash(key, block_mask)

    read_at(ref, slot(block, counter_hash, 0))
    |> min(read_at(ref, slot(block, counter_hash, 1)))
    |> min(read_at(ref, slot(block, counter_hash, 2)))
    |> min(read_at(ref, slot(block, counter_hash, 3)))
  end

  @doc "Zeroes every counter (`Theine.clear/1`, maintenance restart)."
  @spec clear(t()) :: :ok
  def clear(%__MODULE__{ref: ref, words: words}) do
    clear_words(ref, words)
  end

  @doc "The raw words, for tests."
  @spec dump(t()) :: [non_neg_integer()]
  def dump(%__MODULE__{ref: ref, words: words}) do
    for i <- 1..words, do: :atomics.get(ref, i)
  end

  @doc false
  # The `{index, offset}` of the key's four counters: `index` is the 0-based
  # word within the array and `offset` the bit offset of the nibble. Pinned
  # by the layout vectors in sketch_test (specs/02 §Hashing).
  @spec positions(t(), term()) :: [{non_neg_integer(), 0..60}, ...]
  def positions(%__MODULE__{block_mask: block_mask}, key) do
    {block, counter_hash} = hash(key, block_mask)

    for i <- 0..3 do
      {index, offset} = slot(block, counter_hash, i)
      {index - 1, offset}
    end
  end

  # One block hash picks the block, a rehash of it picks the counters, so the
  # bits that chose the block do not also choose counter 0 (specs/02 §Hashing).
  defp hash(key, block_mask) do
    block_hash = key |> :erlang.phash2(4_294_967_296) |> spread()
    {(block_hash &&& block_mask) <<< 3, rehash(block_hash)}
  end

  # The single definition of the layout: counter `i` of a key is in word
  # `block + 2i + (h &&& 1)` (1-based for :atomics) at nibble `(h >>> 1) &&& 15`.
  defp slot(block, counter_hash, i) do
    h = counter_hash >>> (i <<< 3)
    {block + (i <<< 1) + (h &&& 1) + 1, (h >>> 1 &&& 15) <<< 2}
  end

  defp increment_at(ref, {index, offset}) do
    word = :atomics.get(ref, index)

    if (word >>> offset &&& @nibble) != @nibble do
      :atomics.add(ref, index, 1 <<< offset)
    end

    :ok
  end

  defp read_at(ref, {index, offset}) do
    :atomics.get(ref, index) >>> offset &&& @nibble
  end

  defp clear_words(_ref, 0), do: :ok

  defp clear_words(ref, i) do
    :atomics.put(ref, i, 0)
    clear_words(ref, i - 1)
  end

  # Caffeine's 32-bit mixers, with the multiplications masked to 32 bits.
  defp spread(h) do
    h = bxor(h, h >>> 17)
    h = h * 0xED5AD4BB &&& @mask32
    h = bxor(h, h >>> 11)
    h = h * 0xAC4C1B51 &&& @mask32
    bxor(h, h >>> 15)
  end

  defp rehash(h) do
    h = h * 0x31848BAB &&& @mask32
    bxor(h, h >>> 14)
  end

  defp ceil_pow2(n, acc) when acc >= n, do: acc
  defp ceil_pow2(n, acc), do: ceil_pow2(n, acc <<< 1)
end
