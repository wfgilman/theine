defmodule Theine.Entry do
  @moduledoc """
  Layout of the entries table and the read/write primitives on it (specs/01).

  An entry is the tuple

      {key, value, id, weight, written_at, expires_at}
        1    2      3   4       5           6

  - `id`: integer ≥ 1 from the cache's id counter, a fresh one per write.
    0 is reserved to mean "empty slot" in the read buffer.
  - `weight`: integer ≥ 1, from the `weight:` option, else the cache's
    weigher, else 1. An entry heavier than `max_size` is never stored.
  - `written_at`: monotonic milliseconds at write, from `Theine.Clock.now/1`.
  - `expires_at`: monotonic milliseconds, or `:infinity`.

  The read path lives in `Theine.get/2` itself, so that a hit pays no call
  into this module; `expired/2` is its only out-of-line branch. `put/4` here
  is the write path, with `put_new/4` and `delete/2` beside it. Both are
  hot paths (AGENTS.md).
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
  The write path (specs/01 §Write path): weigh the entry, allocate an id,
  insert the entry, then deliver `{:put, key, id, weight, expires_at}` to
  the maintenance process.

  Options: `ttl:` milliseconds or `:infinity` (default: the cache's
  `expire_after_write`), `weight:` a positive integer (default: the cache's
  weigher applied to the key and value, else 1).

  An entry whose weight exceeds `max_size` is not stored and sends no
  event; the call still returns `:ok` (Caffeine rejects oversized entries
  silently).
  """
  @spec put(Config.t(), key(), value(), keyword()) :: :ok
  def put(%Config{} = config, key, value, opts) when is_list(opts) do
    case weight(config, key, value, opts) do
      :oversized ->
        :ok

      weight ->
        now = Theine.Clock.now(config.name)
        expires_at = expires_at(Keyword.get(opts, :ttl, config.expire_after_write), now)
        id = :atomics.add_get(config.ids, 1, 1)
        true = :ets.insert(config.table, {key, value, id, weight, now, expires_at})
        WriteEvents.deliver(config, {:put, key, id, weight, expires_at})
    end
  end

  @doc """
  `put/4` with `:ets.insert_new/2`: stores the entry only when `key` is
  absent, returning `:ok`, else returns `{:error, :exists}` and sends no
  event. An expired entry counts as absent (specs/06 §Semantics): it is
  deleted by exact object, reported as `{:removed, key, id}` and counted as
  an expiration, and the insert is retried. Oversized entries are rejected
  as in `put/4`.
  """
  @spec put_new(Config.t(), key(), value(), keyword()) :: :ok | {:error, :exists}
  def put_new(%Config{} = config, key, value, opts) when is_list(opts) do
    case weight(config, key, value, opts) do
      :oversized -> :ok
      weight -> insert_new(config, key, value, weight, opts)
    end
  end

  defp insert_new(%Config{table: table} = config, key, value, weight, opts) do
    now = Theine.Clock.now(config.name)
    expires_at = expires_at(Keyword.get(opts, :ttl, config.expire_after_write), now)
    id = :atomics.add_get(config.ids, 1, 1)

    if :ets.insert_new(table, {key, value, id, weight, now, expires_at}) do
      WriteEvents.deliver(config, {:put, key, id, weight, expires_at})
    else
      case :ets.lookup(table, key) do
        [{_, _, old_id, _, _, old_expires_at} = old]
        when is_integer(old_expires_at) and now >= old_expires_at ->
          # Logically absent. Remove exactly the tuple seen, as the
          # expired-read branch does, then try again against whatever is
          # there now.
          true = :ets.delete_object(table, old)
          WriteEvents.deliver(config, {:removed, key, old_id})
          :counters.add(config.counters, @expirations, 1)
          insert_new(config, key, value, weight, opts)

        [_live] ->
          {:error, :exists}

        [] ->
          # Deleted between the insert_new and the lookup: try again.
          insert_new(config, key, value, weight, opts)
      end
    end
  end

  @doc """
  `Theine.delete/2` (specs/01 §Write path): looks up the current version of
  `key`, deletes exactly that tuple, and delivers `{:removed, key, id}`. An
  absent key sends nothing. A `put` racing the delete inserts a different
  id, so the fresh tuple survives and the policy ignores the stale removal.
  Always returns `:ok`.
  """
  @spec delete(Config.t(), key()) :: :ok
  def delete(%Config{table: table} = config, key) do
    case :ets.lookup(table, key) do
      [{_, _, id, _, _, _} = entry] ->
        true = :ets.delete_object(table, entry)
        WriteEvents.deliver(config, {:removed, key, id})

      [] ->
        :ok
    end
  end

  # The entry's weight from the `weight:` option, else the weigher, else 1;
  # `:oversized` when it exceeds a finite `max_size` (specs/01 §Write path).
  @spec weight(Config.t(), key(), value(), keyword()) :: weight() | :oversized
  defp weight(%Config{max_size: max_size, weigher: weigher}, key, value, opts) do
    weight =
      case Keyword.fetch(opts, :weight) do
        {:ok, w} -> weight_option(w)
        :error -> weigh(weigher, key, value)
      end

    if is_integer(max_size) and weight > max_size, do: :oversized, else: weight
  end

  defp weight_option(w) when is_integer(w) and w > 0, do: w

  defp weight_option(other) do
    raise ArgumentError, "option :weight must be a positive integer, got: #{inspect(other)}"
  end

  defp weigh(nil, _key, _value), do: 1

  defp weigh(weigher, key, value) do
    case weigher.(key, value) do
      w when is_integer(w) and w > 0 ->
        w

      other ->
        raise ArgumentError,
              "the weigher must return a positive integer, got: #{inspect(other)}"
    end
  end

  defp expires_at(:infinity, _now), do: :infinity
  defp expires_at(ttl, now) when is_integer(ttl) and ttl > 0, do: now + ttl

  defp expires_at(other, _now) do
    raise ArgumentError,
          "option :ttl must be a positive number of milliseconds or :infinity, got: #{inspect(other)}"
  end
end
