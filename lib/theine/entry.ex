defmodule Theine.Entry do
  @moduledoc """
  Layout of the entries table and the read/write primitives on it (specs/01).

  An entry is the tuple

      {key, value, id, weight, written_at, expires_at}
        1    2      3   4       5           6

  - `id`: integer ≥ 1 from the cache's id counter, a fresh one per write.
    0 is reserved to mean "empty slot" in the read buffer.
  - `weight`: integer ≥ 1 (the `weight:` option; the weigher arrives in M1.5).
  - `written_at`: monotonic milliseconds at write, from `Theine.Clock.now/1`.
  - `expires_at`: monotonic milliseconds, or `:infinity`.

  The read path lives in `Theine.get/2` itself, so that a hit pays no call
  into this module; `expired/2` is its only out-of-line branch. `put/4` here
  is the write path. Both are hot paths (AGENTS.md).
  """

  alias Theine.{Config, WriteEvents}

  require Theine.Clock

  @type key :: term()
  @type value :: term()
  @type id :: pos_integer()
  @type weight :: pos_integer()
  @type expires_at :: integer() | :infinity
  @type t :: {key(), value(), id(), weight(), integer(), expires_at()}

  # Tuple positions, 1-based as :ets.update_element/3 and lookup_element/3 want.
  @key 1
  @value 2
  @id 3
  @weight 4
  @written_at 5
  @expires_at 6

  # :counters fields in the specs/08 §Stats order (hits, misses, loads,
  # load_failures, evictions, expirations, refreshes). Theine.Stats names
  # them in M1.6; the indices here and in Theine must stay in step with it.
  @misses 2
  @expirations 6

  @doc "Position of the key in an entry tuple."
  @spec key_pos() :: 1
  def key_pos, do: @key

  @doc "Position of the value in an entry tuple."
  @spec value_pos() :: 2
  def value_pos, do: @value

  @doc "Position of the id in an entry tuple."
  @spec id_pos() :: 3
  def id_pos, do: @id

  @doc "Position of the weight in an entry tuple."
  @spec weight_pos() :: 4
  def weight_pos, do: @weight

  @doc "Position of `written_at` in an entry tuple."
  @spec written_at_pos() :: 5
  def written_at_pos, do: @written_at

  @doc "Position of `expires_at` in an entry tuple."
  @spec expires_at_pos() :: 6
  def expires_at_pos, do: @expires_at

  @doc """
  The expired-read branch of `Theine.get/2` (specs/01 §Expired read): the
  reader found `entry` past its `expires_at`. Deletes exactly the tuple it
  saw (the only write a read may perform; a concurrent put has a different
  id and survives), reports `{:removed, key, id}` to the maintenance
  process, counts a miss and an expiration, and returns `:error`.
  """
  @spec expired(Config.t(), t()) :: :error
  def expired(%Config{table: table, counters: counters} = config, entry) do
    true = :ets.delete_object(table, entry)
    WriteEvents.deliver(config, {:removed, elem(entry, @key - 1), elem(entry, @id - 1)})
    :counters.add(counters, @misses, 1)
    :counters.add(counters, @expirations, 1)
    :error
  end

  @doc """
  The write path (specs/01 §Write path): allocate an id, insert the entry,
  then deliver `{:put, key, id, weight, expires_at}` to the maintenance
  process.

  Options: `ttl:` milliseconds or `:infinity` (default: the cache's
  `expire_after_write`), `weight:` a positive integer (default 1).
  """
  @spec put(Config.t(), key(), value(), keyword()) :: :ok
  def put(%Config{} = config, key, value, opts) when is_list(opts) do
    weight = weight(Keyword.get(opts, :weight, 1))
    now = Theine.Clock.now(config.name)
    expires_at = expires_at(Keyword.get(opts, :ttl, config.expire_after_write), now)
    id = :atomics.add_get(config.ids, 1, 1)
    true = :ets.insert(config.table, {key, value, id, weight, now, expires_at})
    WriteEvents.deliver(config, {:put, key, id, weight, expires_at})
  end

  defp weight(w) when is_integer(w) and w > 0, do: w

  defp weight(other) do
    raise ArgumentError, "option :weight must be a positive integer, got: #{inspect(other)}"
  end

  defp expires_at(:infinity, _now), do: :infinity
  defp expires_at(ttl, now) when is_integer(ttl) and ttl > 0, do: now + ttl

  defp expires_at(other, _now) do
    raise ArgumentError,
          "option :ttl must be a positive number of milliseconds or :infinity, got: #{inspect(other)}"
  end
end
