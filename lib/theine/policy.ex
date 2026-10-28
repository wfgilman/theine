defmodule Theine.Policy do
  @moduledoc """
  The policy's view of the cache's keys (specs/05 §State). Runs only inside
  the maintenance process; the tables are private to it.

      policy  :set   {key, id, segment, seq, weight, expires_at}
      ids     :set   {id, key}

  This is the unbounded mode: `max_size: :infinity` disables admission and
  eviction, so there is no `order` table and no sketch (specs/08 §Starting a
  cache), and `segment` is `nil`. The tables still track every key so that
  `Theine.size/1` and `Theine.weighted_size/1` never need `:ets.info/2` and
  the expiry index (specs/06) can find each key's previous `expires_at`. The
  bounded mode with the three segments arrives in M2.4.

  `size` and `weighted_size` are published to the cache's `sizes` atomics as
  each event is applied, so readers see them without a call to the process.
  """

  alias Theine.{Config, Entry}

  @type segment :: :window | :probation | :protected | nil
  @type row ::
          {Entry.key(), Entry.id(), segment(), pos_integer(), Entry.weight(), Entry.expires_at()}

  @type t :: %__MODULE__{
          policy: :ets.table(),
          ids: :ets.table(),
          table: Config.cache(),
          sizes: :atomics.atomics_ref(),
          max_size: pos_integer() | :infinity,
          next_seq: pos_integer()
        }

  @enforce_keys [:policy, :ids, :table, :sizes, :max_size]
  defstruct [:policy, :ids, :table, :sizes, :max_size, next_seq: 1]

  # Positions in a policy row (1-based, for :ets.update_element/3).
  @row_id 2
  @row_weight 5
  @row_expires_at 6

  # Fields of the `sizes` atomics (allocated by Theine.Owner).
  @size 1
  @weighted_size 2

  @doc "Index of the entry count in `config.sizes`."
  @spec size_index() :: 1
  def size_index, do: @size

  @doc "Index of the weighted size in `config.sizes`."
  @spec weighted_size_index() :: 2
  def weighted_size_index, do: @weighted_size

  @doc """
  Creates the policy tables, owned by the calling process, and zeroes the
  `sizes` atomics of `config`.
  """
  @spec new(Config.t()) :: t()
  def new(%Config{table: table, sizes: sizes, max_size: max_size}) do
    state = %__MODULE__{
      policy: :ets.new(__MODULE__, [:set, :private]),
      ids: :ets.new(__MODULE__.Ids, [:set, :private]),
      table: table,
      sizes: sizes,
      max_size: max_size
    }

    publish(state, 0, 0)
    state
  end

  @doc """
  Applies a `{:put, key, id, weight, expires_at}` event (specs/05 §Events
  `on_write`).

  - unknown key: a new row and a new ids row;
  - known key, different id: the ids row is replaced and the row's id,
    weight and expires_at updated (an access, once the bound exists);
  - known key, same id: weight and expires_at updated only (an `expire/3`
    or `persist/2` update is not an access).
  """
  @spec on_write(t(), Entry.key(), Entry.id(), Entry.weight(), Entry.expires_at()) :: t()
  def on_write(%__MODULE__{} = state, key, id, weight, expires_at) do
    case :ets.lookup(state.policy, key) do
      [] ->
        seq = state.next_seq
        true = :ets.insert(state.policy, {key, id, nil, seq, weight, expires_at})
        true = :ets.insert(state.ids, {id, key})
        add(state, 1, weight)
        %{state | next_seq: seq + 1}

      [{^key, ^id, _segment, _seq, old_weight, _old_expires_at}] ->
        true =
          :ets.update_element(state.policy, key, [
            {@row_weight, weight},
            {@row_expires_at, expires_at}
          ])

        add(state, 0, weight - old_weight)
        state

      [{^key, old_id, _segment, _seq, old_weight, _old_expires_at}] ->
        true = :ets.delete(state.ids, old_id)
        true = :ets.insert(state.ids, {id, key})

        true =
          :ets.update_element(state.policy, key, [
            {@row_id, id},
            {@row_weight, weight},
            {@row_expires_at, expires_at}
          ])

        add(state, 0, weight - old_weight)
        state
    end
  end

  @doc """
  Applies a `{:removed, key, id}` event (specs/05 §Events `on_remove`).

  The rows are deleted when `id` is the key's current id. A removal with
  another id is stale, and the row is kept while the entries table still
  holds the key: a newer version's `:put` is in flight or already applied.
  When the table lacks the key, the row is dropped: two writers racing on
  one key can apply their `:put` events in the opposite order to their
  inserts, leaving the row with an id the table never kept, and the removal
  of the surviving version is the moment to notice (specs/05 §Decisions).
  """
  @spec on_remove(t(), Entry.key(), Entry.id()) :: t()
  def on_remove(%__MODULE__{} = state, key, id) do
    case :ets.lookup(state.policy, key) do
      [{^key, ^id, _segment, _seq, weight, _expires_at}] ->
        drop(state, key, id, weight)

      [{^key, row_id, _segment, _seq, weight, _expires_at}] ->
        if :ets.member(state.table, key), do: state, else: drop(state, key, row_id, weight)

      [] ->
        state
    end
  end

  defp drop(state, key, id, weight) do
    true = :ets.delete(state.policy, key)
    true = :ets.delete(state.ids, id)
    add(state, -1, -weight)
    state
  end

  @doc "Empties the tables and zeroes the published sizes (`Theine.clear/1`)."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = state) do
    true = :ets.delete_all_objects(state.policy)
    true = :ets.delete_all_objects(state.ids)
    publish(state, 0, 0)
    state
  end

  @doc "The policy row of `key`, for tests and `info/1`."
  @spec lookup(t(), Entry.key()) :: {:ok, row()} | :error
  def lookup(%__MODULE__{policy: policy}, key) do
    case :ets.lookup(policy, key) do
      [row] -> {:ok, row}
      [] -> :error
    end
  end

  @doc "Number of keys in the policy table (an `:ets.info/2` call; tests only)."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{policy: policy}), do: :ets.info(policy, :size)

  @doc "Number of rows in the ids table (tests only)."
  @spec id_count(t()) :: non_neg_integer()
  def id_count(%__MODULE__{ids: ids}), do: :ets.info(ids, :size)

  @doc "Entry count as published to the `sizes` atomics."
  @spec size(:atomics.atomics_ref()) :: non_neg_integer()
  def size(sizes), do: :atomics.get(sizes, @size)

  @doc "Weighted size as published to the `sizes` atomics."
  @spec weighted_size(:atomics.atomics_ref()) :: non_neg_integer()
  def weighted_size(sizes), do: :atomics.get(sizes, @weighted_size)

  defp add(%__MODULE__{sizes: sizes}, entries, weight) do
    if entries != 0, do: :atomics.add(sizes, @size, entries)
    if weight != 0, do: :atomics.add(sizes, @weighted_size, weight)
    :ok
  end

  defp publish(%__MODULE__{sizes: sizes}, size, weighted_size) do
    :atomics.put(sizes, @size, size)
    :atomics.put(sizes, @weighted_size, weighted_size)
  end
end
