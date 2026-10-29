defmodule Theine.Policy do
  @moduledoc """
  The policy's view of the cache's keys: W-TinyLFU as Caffeine implements it
  (specs/05). Runs only inside the maintenance process; the tables are
  private to it.

      policy  :set          {key, id, segment, seq, weight, expires_at}
      order   :ordered_set  {{segment, seq}, key}
      ids     :set          {id, key}

  In a bounded cache (`max_size` an integer) every key sits in one of three
  LRU segments, `:window`, `:probation` or `:protected`, ordered by `seq`:
  a monotonically increasing integer assigned on every placement, so a
  larger `seq` means more recently used. The LRU end of a segment is the
  first `order` key after `{segment, 0}` and the MRU end the last key
  before `{segment, max_seq()}` (specs/05 §State). New keys enter at the
  window MRU and an overwrite is an access that moves the key to the MRU of
  its current segment; both count the key in the frequency sketch
  (specs/02). Admission and eviction (`evict/1`) and read-driven promotion
  (`on_access/2`) arrive with M2.6 and M2.5.

  `max_size: :infinity` disables admission and eviction (specs/08 §Starting
  a cache): there is no `order` table and no sketch, and `segment` is `nil`.
  The tables still track every key so that `Theine.size/1` and
  `Theine.weighted_size/1` never need `:ets.info/2` and the expiry index
  (specs/06) can find each key's previous `expires_at`.

  `size` and `weighted_size` are published to the cache's `sizes` atomics as
  each event is applied, so readers see them without a call to the process.
  The three segment weights, the region limits and the number of sketch
  increments since the last completed reset (specs/04 §Responsibilities)
  live in the struct.
  """

  import Bitwise

  alias Theine.{Config, Entry, Sketch}

  @type segment :: :window | :probation | :protected | nil
  @type row ::
          {Entry.key(), Entry.id(), segment(), pos_integer(), Entry.weight(), Entry.expires_at()}

  @typedoc "The three region limits of a bounded policy (specs/05 §Regions and sizes)."
  @type limits :: %{
          window_max: pos_integer(),
          main_max: non_neg_integer(),
          protected_max: non_neg_integer()
        }

  @typedoc "The weight held by each segment."
  @type weights :: %{
          window: non_neg_integer(),
          probation: non_neg_integer(),
          protected: non_neg_integer()
        }

  @type t :: %__MODULE__{
          policy: :ets.table(),
          ids: :ets.table(),
          order: :ets.table() | nil,
          table: Config.cache(),
          sizes: :atomics.atomics_ref(),
          sketch: Sketch.t() | nil,
          max_size: pos_integer() | :infinity,
          window_max: pos_integer() | nil,
          protected_max: non_neg_integer() | nil,
          window_weight: non_neg_integer(),
          probation_weight: non_neg_integer(),
          protected_weight: non_neg_integer(),
          sketch_size: non_neg_integer(),
          next_seq: pos_integer()
        }

  @enforce_keys [:policy, :ids, :table, :sizes, :max_size]
  defstruct [
    :policy,
    :ids,
    :order,
    :table,
    :sizes,
    :sketch,
    :max_size,
    :window_max,
    :protected_max,
    window_weight: 0,
    probation_weight: 0,
    protected_weight: 0,
    sketch_size: 0,
    next_seq: 1
  ]

  # Positions in a policy row (1-based, for :ets.update_element/3).
  @row_id 2
  @row_segment 3
  @row_seq 4
  @row_weight 5
  @row_expires_at 6

  # Fields of the `sizes` atomics (allocated by Theine.Owner).
  @size 1
  @weighted_size 2

  # Upper sentinel of the `order` table (specs/05 §State): `{segment,
  # @max_seq}` sorts after every live `{segment, seq}`, and `seq` must never
  # reach it. Atoms sort after integers, so `:infinity` could not serve.
  @max_seq 1 <<< 62

  @doc "Index of the entry count in `config.sizes`."
  @spec size_index() :: 1
  def size_index, do: @size

  @doc "Index of the weighted size in `config.sizes`."
  @spec weighted_size_index() :: 2
  def weighted_size_index, do: @weighted_size

  @doc """
  The `seq` sentinel: `{segment, max_seq()}` is the upper bound of a segment
  in the `order` table, and no row is ever given it.

      iex> Theine.Policy.max_seq()
      4_611_686_018_427_387_904
  """
  @spec max_seq() :: 4_611_686_018_427_387_904
  def max_seq, do: @max_seq

  @doc """
  The region limits for `max_size` and `window_percent` (specs/05 §Regions
  and sizes): the window gets `window_percent` of the weight, at least 1,
  and the protected segment 80% of what remains.

      iex> Theine.Policy.limits(1_000, 1)
      %{window_max: 10, main_max: 990, protected_max: 792}
      iex> Theine.Policy.limits(1, 1)
      %{window_max: 1, main_max: 0, protected_max: 0}
  """
  @spec limits(pos_integer(), 1..80) :: limits()
  def limits(max_size, window_percent)
      when is_integer(max_size) and max_size > 0 and window_percent in 1..80 do
    window_max = max(1, div(max_size * window_percent, 100))
    main_max = max_size - window_max
    %{window_max: window_max, main_max: main_max, protected_max: div(main_max * 80, 100)}
  end

  @doc """
  Creates the policy tables, owned by the calling process, and zeroes the
  `sizes` atomics of `config`. A bounded config brings its sketch, which is
  cleared here so that a restarted maintenance process starts cold
  (specs/04 §Restart semantics).
  """
  @spec new(Config.t()) :: t()
  def new(%Config{table: table, sizes: sizes, max_size: :infinity}) do
    state = %__MODULE__{
      policy: :ets.new(__MODULE__, [:set, :private]),
      ids: :ets.new(__MODULE__.Ids, [:set, :private]),
      table: table,
      sizes: sizes,
      max_size: :infinity
    }

    publish(state, 0, 0)
    state
  end

  def new(%Config{
        table: table,
        sizes: sizes,
        max_size: max_size,
        window_percent: window_percent,
        sketch: %Sketch{} = sketch
      })
      when is_integer(max_size) do
    %{window_max: window_max, protected_max: protected_max} = limits(max_size, window_percent)
    Sketch.clear(sketch)

    state = %__MODULE__{
      policy: :ets.new(__MODULE__, [:set, :private]),
      ids: :ets.new(__MODULE__.Ids, [:set, :private]),
      order: :ets.new(__MODULE__.Order, [:ordered_set, :private]),
      table: table,
      sizes: sizes,
      sketch: sketch,
      max_size: max_size,
      window_max: window_max,
      protected_max: protected_max
    }

    publish(state, 0, 0)
    state
  end

  @doc """
  Applies a `{:put, key, id, weight, expires_at}` event (specs/05 §Events
  `on_write`).

  - unknown key: a new row and a new ids row; in a bounded cache the key
    is placed at the window MRU and counted in the sketch;
  - known key, different id: the ids row is replaced and the row's id,
    weight and expires_at updated; in a bounded cache the key moves to the
    MRU of its current segment and is counted in the sketch, since Caffeine
    treats an update as an access;
  - known key, same id: weight and expires_at updated only (an `expire/3`
    or `persist/2` update is not an access).
  """
  @spec on_write(t(), Entry.key(), Entry.id(), Entry.weight(), Entry.expires_at()) :: t()
  def on_write(%__MODULE__{} = state, key, id, weight, expires_at) do
    case :ets.lookup(state.policy, key) do
      [] ->
        insert(state, key, id, weight, expires_at)

      [{^key, ^id, segment, _seq, old_weight, _old_expires_at}] ->
        true =
          :ets.update_element(state.policy, key, [
            {@row_weight, weight},
            {@row_expires_at, expires_at}
          ])

        add(state, 0, weight - old_weight)
        add_segment(state, segment, weight - old_weight)

      [{^key, old_id, segment, old_seq, old_weight, _old_expires_at}] ->
        # The access first: it claims the seq, and a refused seq (the
        # sentinel) must leave every table untouched.
        state = touch(state, key, segment, old_seq)
        true = :ets.delete(state.ids, old_id)
        true = :ets.insert(state.ids, {id, key})

        true =
          :ets.update_element(state.policy, key, [
            {@row_id, id},
            {@row_weight, weight},
            {@row_expires_at, expires_at}
          ])

        add(state, 0, weight - old_weight)
        add_segment(state, segment, weight - old_weight)
    end
  end

  defp insert(%__MODULE__{order: nil} = state, key, id, weight, expires_at) do
    seq = next_seq(state)
    true = :ets.insert(state.policy, {key, id, nil, seq, weight, expires_at})
    true = :ets.insert(state.ids, {id, key})
    add(state, 1, weight)
    %{state | next_seq: seq + 1}
  end

  defp insert(%__MODULE__{} = state, key, id, weight, expires_at) do
    seq = next_seq(state)
    true = :ets.insert(state.policy, {key, id, :window, seq, weight, expires_at})
    true = :ets.insert(state.ids, {id, key})
    true = :ets.insert(state.order, {{:window, seq}, key})
    add(state, 1, weight)

    %{state | next_seq: seq + 1, window_weight: state.window_weight + weight}
    |> sample(key)
  end

  # An access: move `key` to the MRU of `segment` and count it in the
  # sketch. Nothing to do without a bound.
  defp touch(%__MODULE__{order: nil} = state, _key, nil, _old_seq), do: state

  defp touch(%__MODULE__{} = state, key, segment, old_seq) do
    state |> move(key, segment, old_seq, segment) |> sample(key)
  end

  # Moves `key` from `{from, old_seq}` to the MRU end of `to` with a fresh
  # seq (one delete and one insert on `order`, one update on `policy`).
  defp move(%__MODULE__{} = state, key, from, old_seq, to) do
    seq = next_seq(state)
    true = :ets.delete(state.order, {from, old_seq})
    true = :ets.insert(state.order, {{to, seq}, key})
    true = :ets.update_element(state.policy, key, [{@row_segment, to}, {@row_seq, seq}])
    %{state | next_seq: seq + 1}
  end

  # Counts one access to `key` in the sketch; `sketch_size` is what the
  # maintenance process compares with `Sketch.sample_size/1` to start a
  # reset (specs/02 §Operations).
  defp sample(%__MODULE__{sketch: sketch, sketch_size: size} = state, key) do
    :ok = Sketch.increment(sketch, key)
    %{state | sketch_size: size + 1}
  end

  defp next_seq(%__MODULE__{next_seq: seq}) when seq < @max_seq, do: seq

  defp next_seq(%__MODULE__{next_seq: seq}) do
    raise "Theine.Policy seq #{seq} reached the order sentinel #{@max_seq}"
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
      [{^key, ^id, _segment, _seq, _weight, _expires_at} = row] ->
        drop(state, row)

      [{^key, _row_id, _segment, _seq, _weight, _expires_at} = row] ->
        if :ets.member(state.table, key), do: state, else: drop(state, row)

      [] ->
        state
    end
  end

  defp drop(state, {key, id, segment, seq, weight, _expires_at}) do
    true = :ets.delete(state.policy, key)
    true = :ets.delete(state.ids, id)
    if state.order, do: true = :ets.delete(state.order, {segment, seq})
    add(state, -1, -weight)
    add_segment(state, segment, -weight)
  end

  @doc """
  Empties the tables, zeroes the published sizes and the segment weights,
  and clears the sketch (`Theine.clear/1`).
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = state) do
    true = :ets.delete_all_objects(state.policy)
    true = :ets.delete_all_objects(state.ids)
    if state.order, do: true = :ets.delete_all_objects(state.order)
    if state.sketch, do: :ok = Sketch.clear(state.sketch)
    publish(state, 0, 0)
    %{state | window_weight: 0, probation_weight: 0, protected_weight: 0, sketch_size: 0}
  end

  @doc "The policy row of `key`, for tests and `info/1`."
  @spec lookup(t(), Entry.key()) :: {:ok, row()} | :error
  def lookup(%__MODULE__{policy: policy}, key) do
    case :ets.lookup(policy, key) do
      [row] -> {:ok, row}
      [] -> :error
    end
  end

  @doc """
  The key at the LRU end of `segment`, or `:error` when the segment is
  empty. Bounded policies only.
  """
  @spec lru(t(), :window | :probation | :protected) :: {:ok, Entry.key()} | :error
  def lru(%__MODULE__{order: order}, segment) when not is_nil(order) do
    end_of(order, segment, :ets.next(order, {segment, 0}))
  end

  @doc """
  The key at the MRU end of `segment`, or `:error` when the segment is
  empty. Bounded policies only.
  """
  @spec mru(t(), :window | :probation | :protected) :: {:ok, Entry.key()} | :error
  def mru(%__MODULE__{order: order}, segment) when not is_nil(order) do
    end_of(order, segment, :ets.prev(order, {segment, @max_seq}))
  end

  defp end_of(order, segment, {segment, _seq} = order_key),
    do: {:ok, :ets.lookup_element(order, order_key, 2)}

  defp end_of(_order, _segment, _other), do: :error

  @doc "The weight held by each segment (zero everywhere without a bound)."
  @spec weights(t()) :: weights()
  def weights(%__MODULE__{} = state) do
    %{
      window: state.window_weight,
      probation: state.probation_weight,
      protected: state.protected_weight
    }
  end

  @doc "The `order` rows, LRU first within each segment (tests only)."
  @spec order_rows(t()) :: [{{segment(), pos_integer()}, Entry.key()}]
  def order_rows(%__MODULE__{order: nil}), do: []
  def order_rows(%__MODULE__{order: order}), do: :ets.tab2list(order)

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

  defp add_segment(state, nil, _delta), do: state

  defp add_segment(%{window_weight: w} = state, :window, delta),
    do: %{state | window_weight: w + delta}

  defp add_segment(%{probation_weight: w} = state, :probation, delta),
    do: %{state | probation_weight: w + delta}

  defp add_segment(%{protected_weight: w} = state, :protected, delta),
    do: %{state | protected_weight: w + delta}

  defp publish(%__MODULE__{sizes: sizes}, size, weighted_size) do
    :atomics.put(sizes, @size, size)
    :atomics.put(sizes, @weighted_size, weighted_size)
  end
end
