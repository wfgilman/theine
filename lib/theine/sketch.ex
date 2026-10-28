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

  Aging (specs/02 §Operations `reset/1`): once the caller has counted
  `sample_size/1` increments it starts a reset with `reset_start/0` and
  advances it one chunk per maintenance pass with `reset/3`, which halves
  every counter in at most `chunk` words and returns the new cursor, or
  `{:done, odd}` when the last word has been halved. `odd` is the number of
  nibbles that were odd before halving; the caller's new increment count is
  `size_after_reset/2`. `reset/1` runs the whole reset in one call.
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

  @typedoc """
  A reset in progress: the 1-based index of the next word to halve and the
  odd nibbles counted so far. Kept by the maintenance process between passes.
  """
  @type reset_cursor :: {next_word :: pos_integer(), odd :: non_neg_integer()}

  @min_words 8
  @max_words 1 <<< 30
  @mask32 0xFFFFFFFF
  @nibble 0xF
  @reset_chunk 16_384
  # Clears the top bit of every nibble of a 32-bit half after the shift, so
  # no counter's low bit leaks into its neighbour.
  @reset_mask32 0x77777777
  # The low bit of every nibble of a 32-bit half.
  @one_mask32 0x11111111

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

  @doc """
  The number of increments after which the caller starts a reset:
  `10 * max_size` (specs/02 §Layout).

      iex> Theine.Sketch.sample_size(1_000)
      10000
  """
  @spec sample_size(pos_integer()) :: pos_integer()
  def sample_size(max_size) when is_integer(max_size) and max_size > 0, do: 10 * max_size

  @doc """
  The default number of words `reset/3` halves per call (specs/02
  §Operations and §Decisions M2.2, specs/04 §Budget). About 1.5 ms on the
  reference machine for a chunk whose words are mostly in use.

      iex> Theine.Sketch.reset_chunk()
      16384
  """
  @spec reset_chunk() :: 16_384
  def reset_chunk, do: @reset_chunk

  @doc "The cursor of a reset that has not halved any word yet."
  @spec reset_start() :: {1, 0}
  def reset_start, do: {1, 0}

  @doc """
  Halves every counter in one call and returns the number of nibbles that
  were odd, for `size_after_reset/2`. Equivalent to calling `reset/3` from
  `reset_start/0` until it returns `{:done, odd}`.
  """
  @spec reset(t()) :: non_neg_integer()
  def reset(%__MODULE__{} = sketch), do: reset_to_end(sketch, reset_start())

  @doc """
  Advances a reset by at most `chunk` words: each word `w` in the chunk
  becomes `(w >>> 1) &&& 0x7777777777777777`, halving its 16 counters, and
  its odd nibbles are added to the cursor's count. Returns `{:more, cursor}`
  while words remain and `{:done, odd}` once the last word has been halved
  (specs/02 §Operations).

  Counters past the cursor keep their old value until a later chunk reaches
  them, so between calls `frequency/2` is somewhere in `[old >>> 1, old]`.
  """
  @spec reset(t(), reset_cursor(), pos_integer()) ::
          {:more, reset_cursor()} | {:done, non_neg_integer()}
  def reset(%__MODULE__{ref: ref, words: words}, {next, odd}, chunk \\ @reset_chunk)
      when is_integer(next) and next >= 1 and next <= words and is_integer(chunk) and chunk > 0 do
    last = min(next + chunk - 1, words)
    odd = halve_words(ref, next, last, odd)

    if last == words, do: {:done, odd}, else: {:more, {last + 1, odd}}
  end

  @doc """
  The caller's increment count once a reset has completed with `odd` odd
  nibbles: `(size - (odd >>> 2)) >>> 1`, Caffeine's rule (specs/02
  §Operations). Each increment touches four counters, so `odd >>> 2`
  estimates the increments whose halving truncated. Clamped at 0, which only
  matters for a sketch of a few words whose residue from an earlier reset
  can leave more odd nibbles than `4 * size`.

      iex> Theine.Sketch.size_after_reset(10_000, 4_000)
      4500
      iex> Theine.Sketch.size_after_reset(10, 128)
      0
  """
  @spec size_after_reset(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def size_after_reset(size, odd) when is_integer(size) and is_integer(odd) do
    max(size - (odd >>> 2), 0) >>> 1
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

  defp reset_to_end(sketch, cursor) do
    case reset(sketch, cursor, @reset_chunk) do
      {:done, odd} -> odd
      {:more, cursor} -> reset_to_end(sketch, cursor)
    end
  end

  # Halves words `i..last` (1-based, inclusive). A zero word has no odd
  # nibble and halves to itself, so it is read but not written; most words
  # of a sketch below sample_size are zero.
  #
  # The word is split into 32-bit halves before any arithmetic: a word with
  # its top nibble in use is above 2^59 and so a bignum on the BEAM, and
  # bignum shifts and masks ran the loop at about twice the cost of the
  # atomics themselves (specs/02 §Decisions M2.2). Halving the halves
  # separately gives the same result as `(word >>> 1) &&& 0x7777777777777777`:
  # the bit that crosses from the high half is the top bit of nibble 7,
  # which the mask clears anyway.
  defp halve_words(_ref, i, last, odd) when i > last, do: odd

  defp halve_words(ref, i, last, odd) do
    case :atomics.get(ref, i) do
      0 ->
        halve_words(ref, i + 1, last, odd)

      word ->
        lo = word &&& @mask32
        hi = word >>> 32
        :atomics.put(ref, i, (hi >>> 1 &&& @reset_mask32) <<< 32 ||| (lo >>> 1 &&& @reset_mask32))
        halve_words(ref, i + 1, last, odd + odd_nibbles(lo) + odd_nibbles(hi))
    end
  end

  # The number of nibbles of a 32-bit half with their low bit set. Those bits
  # sit at powers of 16, and 16 is 1 modulo 15, so the remainder of their sum
  # by 15 is their count; a half has 8 nibbles, so the count never wraps.
  defp odd_nibbles(half), do: rem(half &&& @one_mask32, 15)

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
