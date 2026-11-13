defmodule Theine.Partition do
  @moduledoc """
  The partition of a key and of an id (specs/12 §The partition of a key,
  §Ids carry the partition).

  A cache with `partitions: n` (a power of two) splits its policy across
  `n` maintenance processes. Every version of a key belongs to one
  partition, the top `log2(n)` bits of the key's 32-bit `:erlang.phash2/2`
  (the hash the sketch starts from, specs/02 §Hashing). Only a writer that
  allocates an id hashes the key: the id it allocates carries the partition
  in its low bits, `id &&& (n - 1)`, so every later step (a delete, an
  expired read, an expiry, a hit) finds the partition in the id it already
  holds.

  At `n = 1` nothing is hashed and an id is the cache's single counter, as
  it was before partitions existed.
  """

  import Bitwise

  @hash_range 4_294_967_296

  @doc """
  The partition of `key` in a cache of `n` partitions: the top `log2(n)`
  bits of `:erlang.phash2(key, 2^32)`, and 0 without hashing at `n = 1`.

  Since the hash is below `2^32` and `n` is a power of two,
  `(hash * n) >>> 32` is those top bits, with no logarithm to compute.

      iex> Theine.Partition.of_key(:anything, 1)
      0
      iex> Theine.Partition.of_key(:anything, 8) in 0..7
      true
  """
  @spec of_key(term(), pos_integer()) :: non_neg_integer()
  def of_key(_key, 1), do: 0
  def of_key(key, n), do: (:erlang.phash2(key, @hash_range) * n) >>> 32

  @doc """
  The partition of `id` in a cache of `n` partitions: its low `log2(n)`
  bits.

      iex> Theine.Partition.of_id(13, 4)
      1
      iex> Theine.Partition.of_id(13, 1)
      0
  """
  @spec of_id(pos_integer(), pos_integer()) :: non_neg_integer()
  def of_id(id, n), do: id &&& n - 1

  @doc """
  Allocates the next id for `key` from `ids`, an `:atomics` array with one
  counter per partition (specs/12 §Ids carry the partition):
  `:atomics.add_get(ids, p + 1, 1) * n + p` for `p = of_key(key, n)`, so
  that `of_id(id, n) == p` and a key's ids increase.

  At `n = 1` this is `:atomics.add_get(ids, 1, 1)`, today's id, and the key
  is not hashed.
  """
  @spec next_id(:atomics.atomics_ref(), pos_integer(), term()) :: pos_integer()
  def next_id(ids, 1, _key), do: :atomics.add_get(ids, 1, 1)

  def next_id(ids, n, key) do
    p = of_key(key, n)
    :atomics.add_get(ids, p + 1, 1) * n + p
  end
end
