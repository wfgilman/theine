defmodule Theine.Expiry do
  @moduledoc """
  The expiration index (specs/06 §Index): a private `ordered_set` owned by
  the maintenance process, beside the policy tables.

      expiry  :ordered_set  {{expires_at, key}, id}

  Only entries with an integer `expires_at` are indexed. Erlang term order
  sorts by `expires_at` first, so the first row is always the next entry to
  expire, and a sweep walks from it while the rows are due. This is the
  ordered-set substitute for Caffeine's timer wheel: O(log n) per insert,
  O(1) amortized per sweep step.

  `Theine.Policy` keeps the index in step with its rows: every place a row
  is inserted, restored, rewritten with a new `expires_at` or dropped calls
  `move/5` or `delete/3` here, from the previous `expires_at` the row
  remembers. The index therefore holds exactly one row per policy row with
  an integer `expires_at`, whatever removed it (an event, an eviction, the
  sweep), and `Theine.Policy.expire/3` is the one caller of `sweep/5`.
  """

  alias Theine.Entry

  @typedoc "An expiration index."
  @type t :: :ets.table()

  @doc "Creates an empty index owned by the calling process."
  @spec new() :: t()
  def new, do: :ets.new(__MODULE__, [:ordered_set, :private])

  @doc """
  Re-indexes `key` from `old` to `new` under `id`: the row at `old` goes and
  one at `new` is written, each only when it is an integer. `old` is `nil`
  for a key the index never held.

      iex> index = Theine.Expiry.new()
      iex> :ok = Theine.Expiry.move(index, :a, 1, nil, 10)
      iex> :ok = Theine.Expiry.move(index, :a, 2, 10, 20)
      iex> Theine.Expiry.rows(index)
      [{{20, :a}, 2}]
  """
  @spec move(t(), Entry.key(), Entry.id(), Entry.expires_at() | nil, Entry.expires_at()) :: :ok
  def move(index, key, id, old, new) do
    if is_integer(old) and old != new, do: true = :ets.delete(index, {old, key})
    if is_integer(new), do: true = :ets.insert(index, {{new, key}, id})
    :ok
  end

  @doc "Removes `key`'s row at `expires_at`, if it is an integer."
  @spec delete(t(), Entry.key(), Entry.expires_at()) :: :ok
  def delete(index, key, expires_at) when is_integer(expires_at) do
    true = :ets.delete(index, {expires_at, key})
    :ok
  end

  def delete(_index, _key, :infinity), do: :ok

  @doc "Empties the index (`Theine.clear/1`)."
  @spec clear(t()) :: :ok
  def clear(index) do
    true = :ets.delete_all_objects(index)
    :ok
  end

  @doc """
  Walks the index from its first row while `expires_at <= now`, at most
  `limit` rows, calling `fun.(key, id, expires_at, acc)` for each. The
  callback is expected to remove the row (through the policy's removal),
  but the walk does not depend on it: it steps with `:ets.next/2`, which
  finds the following row whether or not the current one is still there.

  Returns `{:done, acc}` once the next row is not due, or the index is
  empty, and `{:more, acc}` when it stopped at `limit` with a due row
  left, so the maintenance process can schedule a follow-up pass (specs/04
  §The pass).

      iex> index = Theine.Expiry.new()
      iex> for {key, at} <- [a: 10, b: 20, c: 30], do: Theine.Expiry.move(index, key, 1, nil, at)
      iex> Theine.Expiry.sweep(index, 25, 1, fn key, _id, _at, acc -> [key | acc] end, [])
      {:more, [:a]}
      iex> Theine.Expiry.sweep(index, 25, 10, fn key, _id, _at, acc -> [key | acc] end, [])
      {:done, [:b, :a]}
  """
  @spec sweep(
          t(),
          integer(),
          pos_integer(),
          (Entry.key(), Entry.id(), integer(), acc -> acc),
          acc
        ) ::
          {:done | :more, acc}
        when acc: term()
  def sweep(index, now, limit, fun, acc) when is_integer(limit) and limit > 0 do
    walk(index, :ets.first(index), now, limit, fun, acc)
  end

  defp walk(_index, {expires_at, _key}, now, _limit, _fun, acc) when expires_at > now,
    do: {:done, acc}

  defp walk(_index, :"$end_of_table", _now, _limit, _fun, acc), do: {:done, acc}

  defp walk(_index, _due, _now, 0, _fun, acc), do: {:more, acc}

  defp walk(index, {expires_at, key} = row_key, now, limit, fun, acc) do
    acc = fun.(key, :ets.lookup_element(index, row_key, 2), expires_at, acc)
    walk(index, :ets.next(index, row_key), now, limit - 1, fun, acc)
  end

  @doc "The index rows in order, for tests."
  @spec rows(t()) :: [{{integer(), Entry.key()}, Entry.id()}]
  def rows(index), do: :ets.tab2list(index)

  @doc "The number of indexed entries."
  @spec size(t()) :: non_neg_integer()
  def size(index), do: :ets.info(index, :size)
end
