defmodule Theine.Policy do
  @moduledoc """
  The policy's view of the cache's keys: W-TinyLFU as Caffeine implements it
  (specs/05). Runs only inside the maintenance process; the tables are
  private to it.

      policy  :set          {key, id, segment, seq, weight, expires_at}
      order   :ordered_set  {base(segment) + seq, key}
      ids     :set          {id, key}

  In a bounded cache (`max_size` an integer) every key sits in one of three
  LRU segments, `:window`, `:probation` or `:protected`, ordered by `seq`:
  a monotonically increasing integer assigned on every placement, so a
  larger `seq` means more recently used. An `order` key is the segment's
  base, a multiple of `max_seq()`, plus the seq. The LRU end of a segment is
  the first `order` key after `base(segment)` and the MRU end the last key
  before `base(segment) + max_seq()` (specs/05 §State). New keys enter at the
  window MRU and an overwrite is an access that moves the key to the MRU of
  its current segment; both count the key in the frequency sketch
  (specs/02). A read drained from the read buffer (`on_access/2`) moves the
  key to the MRU of its segment, promoting a probation key to protected.
  `evict/1`, run once per maintenance pass, overflows the window into
  probation and, while the cache is over `max_size`, decides between the
  probation LRU victim and each window overflow by their sketch
  frequencies, removing the loser from the entries table and the tables
  here (specs/05 §Events `evict`).

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

  With `adaptive: true`, the default, `climb/1` moves the window's share of
  `max_size` with Caffeine's hill climber (specs/05 §Adaptive window). Its
  sample is counted here: a current-id `on_access/2` is a hit and a `:put`
  that admits a key new to the policy a miss.
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

  @typedoc """
  The hill climber's state (specs/05 §Adaptive window): the hit rate of the
  previous sample, the signed step the next sample moves the window by, the
  part of the last adjustment not yet transferred (positive grows the
  window), and the limits at the start, which `reset/1` restores.
  """
  @type climber :: %{
          hit_rate: float(),
          step: float(),
          adjustment: integer(),
          window_max: pos_integer(),
          protected_max: non_neg_integer()
        }

  @type t :: %__MODULE__{
          policy: :ets.table(),
          ids: :ets.table(),
          order: :ets.table() | nil,
          table: Config.cache(),
          sizes: :atomics.atomics_ref(),
          counters: :counters.counters_ref(),
          sketch: Sketch.t() | nil,
          max_size: pos_integer() | :infinity,
          window_max: pos_integer() | nil,
          protected_max: non_neg_integer() | nil,
          evict_batch: pos_integer() | nil,
          window_weight: non_neg_integer(),
          probation_weight: non_neg_integer(),
          protected_weight: non_neg_integer(),
          sketch_size: non_neg_integer(),
          next_seq: pos_integer(),
          candidates: non_neg_integer(),
          cursor: non_neg_integer() | nil,
          candidate_floor: pos_integer() | nil,
          restored_id: non_neg_integer(),
          sample_hits: non_neg_integer(),
          sample_misses: non_neg_integer(),
          climber: climber() | nil
        }

  @enforce_keys [:policy, :ids, :table, :sizes, :counters, :max_size]
  defstruct [
    :policy,
    :ids,
    :order,
    :table,
    :sizes,
    :counters,
    :sketch,
    :max_size,
    :window_max,
    :protected_max,
    :evict_batch,
    window_weight: 0,
    probation_weight: 0,
    protected_weight: 0,
    sketch_size: 0,
    next_seq: 1,
    candidates: 0,
    cursor: nil,
    candidate_floor: nil,
    restored_id: 0,
    sample_hits: 0,
    sample_misses: 0,
    climber: nil
  ]

  # Caffeine's hill climber (specs/05 §Adaptive window): a sample of
  # `Sketch.sample_size/1` requests, a first step of 6.25% of `max_size`
  # that decays by 0.98 per sample, back to the full step when the hit rate
  # moved by 5 points or more, and at most 1000 entries moved per call
  # (`QUEUE_TRANSFER_THRESHOLD`), the rest carried to the next pass.
  @step_percent 0.0625
  @step_decay 0.98
  @restart_threshold 0.05
  @transfer_cap 1000

  # Caffeine's hash-DoS guard (specs/05 §Events `evict`): a candidate that
  # ties or loses but has at least this frequency is still admitted one
  # time in 128, so a flood of fresh keys cannot pin the main region.
  @admit_threshold 6
  @admit_odds 128

  # Where an entry tuple keeps its id (specs/01 §Layout).
  @entry_id Entry.id_pos()

  # The `evictions` counter (specs/08 §Stats), resolved at compile time.
  @evictions Theine.Stats.evictions()

  # Positions in a policy row (1-based, for :ets.update_element/3).
  @row_id 2
  @row_segment 3
  @row_seq 4
  @row_weight 5
  @row_expires_at 6

  # Fields of the `sizes` atomics (allocated by Theine.Owner).
  @size 1
  @weighted_size 2

  # Keys of the `order` table (specs/05 §State): the segment's rank in the
  # bits above `@seq_bits` and `seq` below, so `base(segment) + seq` sorts
  # by segment, then seq, and stays a small integer (under 2^59) whatever
  # the segment. An integer key costs the tree walk about 40% less than a
  # `{segment, seq}` tuple (specs/05 §Decisions M2.11b). `seq` must stay
  # below `@max_seq`, so `base(segment)` and `base(segment) + @max_seq`
  # bound a segment and are never keys themselves (`seq` starts at 1).
  @seq_bits 56
  @max_seq 1 <<< @seq_bits
  @seq_mask @max_seq - 1
  @probation_base 1 <<< @seq_bits
  @protected_base 2 <<< @seq_bits
  @window_base 3 <<< @seq_bits

  @doc "Index of the entry count in `config.sizes`."
  @spec size_index() :: 1
  def size_index, do: @size

  @doc "Index of the weighted size in `config.sizes`."
  @spec weighted_size_index() :: 2
  def weighted_size_index, do: @weighted_size

  @doc """
  The `seq` sentinel: every `seq` is below it, so that a segment's `order`
  keys stay within its range, and no row is ever given it.

      iex> Theine.Policy.max_seq()
      72_057_594_037_927_936
  """
  @spec max_seq() :: 72_057_594_037_927_936
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
  def new(%Config{table: table, sizes: sizes, counters: counters, max_size: :infinity}) do
    state = %__MODULE__{
      policy: :ets.new(__MODULE__, [:set, :private]),
      ids: :ets.new(__MODULE__.Ids, [:set, :private]),
      table: table,
      sizes: sizes,
      counters: counters,
      max_size: :infinity
    }

    publish(state, 0, 0)
    state
  end

  def new(%Config{
        table: table,
        sizes: sizes,
        counters: counters,
        max_size: max_size,
        window_percent: window_percent,
        adaptive: adaptive,
        evict_batch: evict_batch,
        sketch: %Sketch{} = sketch
      })
      when is_integer(max_size) do
    %{window_max: window_max, protected_max: protected_max} = limits(max_size, window_percent)
    Sketch.clear(sketch)

    # Caffeine starts the step negative (`setMaximumSize`): the first sample,
    # compared with a rate of 0, shrinks the window toward its minimum.
    climber =
      if adaptive,
        do: %{
          hit_rate: 0.0,
          step: -@step_percent * max_size,
          adjustment: 0,
          window_max: window_max,
          protected_max: protected_max
        }

    state = %__MODULE__{
      policy: :ets.new(__MODULE__, [:set, :private]),
      ids: :ets.new(__MODULE__.Ids, [:set, :private]),
      order: :ets.new(__MODULE__.Order, [:ordered_set, :private]),
      table: table,
      sizes: sizes,
      counters: counters,
      sketch: sketch,
      max_size: max_size,
      window_max: window_max,
      protected_max: protected_max,
      evict_batch: evict_batch,
      climber: climber
    }

    publish(state, 0, 0)
    state
  end

  @doc """
  Applies a `{:put, key, id, weight, expires_at}` event (specs/05 §Events
  `on_write`).

  - unknown key: a new row and a new ids row; in a bounded cache the key
    is placed at the window MRU and counted in the sketch. An `id` at or
    below the highest one `restore/5` admitted may be a version the
    rebuild restored and the policy has since removed, so it is admitted
    only while the entries table still holds it (specs/05 §Decisions
    M2.12);
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
      [] when id <= state.restored_id ->
        if :ets.lookup_element(state.table, key, @entry_id, nil) == id,
          do: insert(state, key, id, weight, expires_at),
          else: state

      [] ->
        insert(state, key, id, weight, expires_at)

      [{^key, ^id, segment, _seq, old_weight, _old_expires_at}] ->
        true =
          :ets.update_element(state.policy, key, [
            {@row_weight, weight},
            {@row_expires_at, expires_at}
          ])

        add(state, 0, weight - old_weight)

        state
        |> add_segment(segment, weight - old_weight)
        |> fit(key, segment, weight, old_weight)

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

        state
        |> add_segment(segment, weight - old_weight)
        |> fit(key, segment, weight, old_weight)
    end
  end

  # After a protected key grew heavier the segment must still fit
  # (specs/05 §Decisions M2.6): a key now heavier than `protected_max`
  # moves to the probation MRU, as a promotion would send it there, and
  # otherwise the protected LRU entries are demoted until the segment fits.
  defp fit(state, key, :protected, weight, old_weight) when weight > old_weight do
    if weight > state.protected_max do
      [{^key, _id, :protected, seq, ^weight, _expires_at}] = :ets.lookup(state.policy, key)

      state
      |> move(key, :protected, seq, :probation)
      |> add_segment(:protected, -weight)
      |> add_segment(:probation, weight)
    else
      demote(state)
    end
  end

  defp fit(state, _key, _segment, _weight, _old_weight), do: state

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
    true = :ets.insert(state.order, {@window_base + seq, key})
    add(state, 1, weight)
    :ok = Sketch.increment(state.sketch, key)

    # A key new to the policy is the climber's miss (specs/05 §Adaptive
    # window): in a cache, the insert of a new key follows a miss.
    %{
      state
      | next_seq: seq + 1,
        window_weight: state.window_weight + weight,
        sketch_size: state.sketch_size + 1,
        sample_misses: state.sample_misses + 1
    }
  end

  # An access: move `key` to the MRU of `segment` and count it in the
  # sketch. Nothing to do without a bound. An overwrite is an access to the
  # policy but neither a hit nor a miss to the climber.
  defp touch(%__MODULE__{order: nil} = state, _key, nil, _old_seq), do: state

  defp touch(%__MODULE__{} = state, key, segment, old_seq),
    do: reorder_and_sample(state, key, segment, old_seq, 0)

  # A move to the MRU of the key's own segment and its sketch count, with
  # one struct update: a struct update costs about as much as an ETS
  # update_element here, and this is the drain's common case (specs/05
  # §Decisions M2.11b). `hit` is 1 for a drained read, the climber's hit.
  defp reorder_and_sample(%__MODULE__{sketch_size: size} = state, key, segment, old_seq, hit) do
    seq = next_seq(state)
    reorder(state, key, segment, old_seq, segment, seq)
    :ok = Sketch.increment(state.sketch, key)
    %{state | next_seq: seq + 1, sketch_size: size + 1, sample_hits: state.sample_hits + hit}
  end

  # Moves `key` from `{from, old_seq}` to the MRU end of `to` with a fresh
  # seq.
  defp move(%__MODULE__{} = state, key, from, old_seq, to) do
    seq = next_seq(state)
    reorder(state, key, from, old_seq, to, seq)
    %{state | next_seq: seq + 1}
  end

  # The table side of a move: one delete and one insert on `order`, one
  # update on `policy`.
  defp reorder(%__MODULE__{order: order, policy: policy}, key, from, old_seq, to, seq) do
    true = :ets.delete(order, base(from) + old_seq)
    true = :ets.insert(order, {base(to) + seq, key})
    true = :ets.update_element(policy, key, [{@row_segment, to}, {@row_seq, seq}])
  end

  @doc """
  Re-admits an entry found in the entries table by a maintenance restart
  (specs/04 §Restart semantics step 3; specs/05 §Events `restore`): a row
  under the table's `id`, `weight` and `expires_at`, placed at the
  **probation** MRU in a bounded cache with no sketch increment, so the
  rebuilt policy is cold and every entry is a candidate for eviction. A key
  the policy already holds is left alone, whatever its id; the rebuild
  scans a fixed table, so that only happens if the caller restores a key
  twice.

  The highest restored id is kept: a restored entry's own `:put` may still
  be queued when the policy evicts it, and `on_write/5` must not bring its
  row back (specs/05 §Decisions M2.12).
  """
  @spec restore(t(), Entry.key(), Entry.id(), Entry.weight(), Entry.expires_at()) :: t()
  def restore(%__MODULE__{order: nil} = state, key, id, weight, expires_at) do
    seq = next_seq(state)

    if :ets.insert_new(state.policy, {key, id, nil, seq, weight, expires_at}) do
      true = :ets.insert(state.ids, {id, key})
      add(state, 1, weight)
      %{state | next_seq: seq + 1, restored_id: max(id, state.restored_id)}
    else
      state
    end
  end

  def restore(%__MODULE__{} = state, key, id, weight, expires_at) do
    seq = next_seq(state)

    if :ets.insert_new(state.policy, {key, id, :probation, seq, weight, expires_at}) do
      true = :ets.insert(state.ids, {id, key})
      true = :ets.insert(state.order, {@probation_base + seq, key})
      add(state, 1, weight)

      %{
        state
        | next_seq: seq + 1,
          probation_weight: state.probation_weight + weight,
          restored_id: max(id, state.restored_id)
      }
    else
      state
    end
  end

  @doc """
  Applies one read of the version `id`, as drained from the read buffer
  (specs/05 §Events `on_access`). Without a bound there is no order to keep
  and no read buffer to drain, so the state is returned unchanged.

  An unknown id, or one that is no longer its key's current id, is a read
  of a version since overwritten or removed and is skipped (specs/04 §The
  pass step 3). Otherwise the key is moved and counted in the sketch:

  - `:window` → window MRU;
  - `:probation` → protected MRU, and while `protected_weight` exceeds
    `protected_max` the protected LRU entries are demoted to probation MRU.
    An entry heavier than `protected_max` on its own would only empty the
    protected segment to be demoted straight back, so it moves to probation
    MRU instead, as Caffeine's `reorderProbation` does (specs/05
    §Decisions M2.5);
  - `:protected` → protected MRU.
  """
  @spec on_access(t(), Entry.id()) :: t()
  def on_access(%__MODULE__{order: nil} = state, _id), do: state

  def on_access(%__MODULE__{} = state, id) do
    with [{^id, key}] <- :ets.lookup(state.ids, id),
         [{^key, ^id, segment, seq, weight, _expires_at}] <- :ets.lookup(state.policy, key) do
      access(state, key, segment, seq, weight)
    else
      _ -> state
    end
  end

  # A promotion: probation → protected MRU, then demote until it fits.
  defp access(%__MODULE__{protected_max: max} = state, key, :probation, seq, weight)
       when weight <= max do
    new_seq = next_seq(state)
    reorder(state, key, :probation, seq, :protected, new_seq)
    :ok = Sketch.increment(state.sketch, key)

    demote(%{
      state
      | next_seq: new_seq + 1,
        sketch_size: state.sketch_size + 1,
        sample_hits: state.sample_hits + 1,
        probation_weight: state.probation_weight - weight,
        protected_weight: state.protected_weight + weight
    })
  end

  # Window → window MRU, protected → protected MRU, and a probation entry
  # too heavy for protected → probation MRU.
  defp access(state, key, segment, seq, _weight),
    do: reorder_and_sample(state, key, segment, seq, 1)

  # Demotes protected LRU entries to probation MRU until the protected
  # segment fits. Every step removes a positive weight, and the segment is
  # never empty while its weight exceeds a non-negative limit.
  defp demote(%__MODULE__{protected_weight: w, protected_max: max} = state) when w <= max,
    do: state

  defp demote(%__MODULE__{order: order, policy: policy} = state) do
    {seq, key} = lru_entry(order, :protected)
    weight = :ets.lookup_element(policy, key, @row_weight)
    new_seq = next_seq(state)
    reorder(state, key, :protected, seq, :probation, new_seq)

    demote(%{
      state
      | next_seq: new_seq + 1,
        protected_weight: state.protected_weight - weight,
        probation_weight: state.probation_weight + weight
    })
  end

  defp next_seq(%__MODULE__{next_seq: seq}) when seq < @max_seq, do: seq

  defp next_seq(%__MODULE__{next_seq: seq}) do
    raise "Theine.Policy seq #{seq} reached the order sentinel #{@max_seq}"
  end

  @doc """
  One eviction step of the maintenance pass (specs/05 §Events `evict`;
  specs/04 §The pass step 5). Returns `{status, evicted, state}` where
  `evicted` is the number of entries removed from the entries table and
  `status` is `:done` when the weight fits `max_size`, or `:more` when the
  pass stopped at `evict_batch` removals while still over it, in which case
  the caller schedules a follow-up pass. Without a bound it is `{:done, 0,
  state}`.

  1. While `window_weight > window_max`, the window LRU entry moves to the
     probation MRU and counts as a candidate.
  2. While the three segment weights sum to more than `max_size`: the
     victim is the probation LRU (the protected LRU when probation is
     empty, the window LRU when both are). With no candidate left the
     victim is removed outright. Otherwise the candidate is the entry under
     the cursor, which starts at the probation MRU and walks toward the LRU
     one entry per decision, so each window overflow is tested once. When
     the candidate is the victim it is removed; else the candidate is
     admitted, and the victim removed, when its sketch frequency exceeds
     the victim's, or with odds of 1 in #{@admit_odds} when it is at least
     #{@admit_threshold} (the hash-DoS guard); otherwise the candidate is
     removed.

  Removal re-reads the entries table and deletes the exact tuple only when
  its id is the policy's (specs/04 §Removing an entry), counting it in
  `evictions`; a key the table holds under another id, or not at all, was
  replaced or deleted concurrently and only its policy rows go, since the
  event already in flight will account for the live version.

  The candidate count and the cursor are carried in the state across a
  `:more` so that a follow-up pass keeps testing the overflows the capped
  pass left; a follow-up whose step 1 appended new overflows restarts the
  cursor at the probation MRU. The walk never goes below the `seq` of the
  batch's first overflow: an entry under it was in probation before the
  batch and has been tested already, so reaching one, or the LRU end,
  settles whatever count is left (specs/05 §Decisions M2.6).
  """
  @spec evict(t()) :: {:done | :more, non_neg_integer(), t()}
  def evict(%__MODULE__{order: nil} = state), do: {:done, 0, state}

  def evict(%__MODULE__{} = state) do
    first_seq = state.next_seq
    {state, overflowed} = overflow(state, 0)

    state =
      if overflowed > 0 do
        %{
          state
          | candidates: state.candidates + overflowed,
            cursor: nil,
            candidate_floor: if(state.candidates == 0, do: first_seq, else: state.candidate_floor)
        }
      else
        state
      end

    evict_main(state, 0, 0)
  end

  # Step 1: window overflow into the probation MRU, each move a candidate.
  defp overflow(%__MODULE__{window_weight: w, window_max: max} = state, n) when w <= max,
    do: {state, n}

  defp overflow(%__MODULE__{order: order, policy: policy} = state, n) do
    {seq, key} = lru_entry(order, :window)
    weight = :ets.lookup_element(policy, key, @row_weight)

    state
    |> move(key, :window, seq, :probation)
    |> add_segment(:window, -weight)
    |> add_segment(:probation, weight)
    |> overflow(n + 1)
  end

  # Step 2, one removal per round, `removals` capped by `evict_batch`.
  defp evict_main(%__MODULE__{} = state, removals, evicted) do
    cond do
      total(state) <= state.max_size ->
        {:done, evicted, settled(state)}

      removals >= state.evict_batch ->
        {:more, evicted, state}

      true ->
        {state, n} = decide(state)
        evict_main(state, removals + 1, evicted + n)
    end
  end

  defp total(%__MODULE__{window_weight: w, probation_weight: p, protected_weight: m}),
    do: w + p + m

  defp decide(%__MODULE__{order: order, candidates: candidates} = state) do
    case lru_entry(order, :probation) do
      {_victim_seq, victim} when candidates == 0 ->
        remove(state, victim)

      {victim_seq, victim} ->
        case candidate(state) do
          nil ->
            # The cursor walked past the batch's overflows: every remaining
            # probation entry has been tested, so the leftover count is
            # settled.
            remove(settled(state), victim)

          {^victim_seq, ^victim} ->
            remove(%{state | candidates: candidates - 1, cursor: 0}, victim)

          {seq, candidate} ->
            # The next cursor position is fixed before anything is deleted.
            state = %{state | candidates: candidates - 1, cursor: previous(order, seq)}

            if admit?(state, candidate, victim),
              do: remove(state, victim),
              else: remove(state, candidate)
        end

      nil ->
        case lru_entry(order, :protected) do
          {_seq, key} ->
            remove(state, key)

          nil ->
            {_seq, key} = lru_entry(order, :window)
            remove(state, key)
        end
    end
  end

  defp settled(state), do: %{state | candidates: 0, cursor: nil, candidate_floor: nil}

  # The entry under the cursor: the probation entry at the cursor's seq
  # when it still exists, else the nearest one below it, as long as it was
  # placed since the batch began. `nil` cursor means the probation MRU, `0`
  # means the walk is over.
  defp candidate(%__MODULE__{order: order, cursor: cursor, candidate_floor: floor}) do
    bound = cursor || @max_seq

    found =
      case :ets.lookup(order, @probation_base + bound) do
        [{_order_key, key}] ->
          {bound, key}

        [] ->
          case :ets.prev(order, @probation_base + bound) do
            order_key when is_integer(order_key) and order_key > @probation_base ->
              {order_key - @probation_base, :ets.lookup_element(order, order_key, 2)}

            _ ->
              nil
          end
      end

    case found do
      {seq, _key} when is_integer(floor) and seq < floor -> nil
      other -> other
    end
  end

  defp previous(order, seq) do
    case :ets.prev(order, @probation_base + seq) do
      order_key when is_integer(order_key) and order_key > @probation_base ->
        order_key - @probation_base

      _ ->
        0
    end
  end

  defp admit?(%__MODULE__{sketch: sketch}, candidate, victim) do
    candidate_freq = Sketch.frequency(sketch, candidate)

    cond do
      candidate_freq > Sketch.frequency(sketch, victim) -> true
      candidate_freq >= @admit_threshold -> :rand.uniform(@admit_odds) == 1
      true -> false
    end
  end

  # Removes `key` (specs/04 §Removing an entry): the entries table keeps a
  # version under another id, or none, when a put or delete raced the
  # policy, and that version's event settles the rows this drops.
  defp remove(%__MODULE__{policy: policy, table: table, counters: counters} = state, key) do
    [{^key, id, _segment, _seq, _weight, _expires_at} = row] = :ets.lookup(policy, key)

    evicted =
      case :ets.lookup(table, key) do
        [{^key, _value, ^id, _weight, _written_at, _expires_at} = entry] ->
          true = :ets.delete_object(table, entry)
          :counters.add(counters, @evictions, 1)
          1

        _replaced_or_gone ->
          0
      end

    {drop(state, row), evicted}
  end

  @doc """
  The adaptive step of the maintenance pass (specs/05 §Adaptive window;
  specs/04 §The pass step 7), Caffeine's `climb`. A no-op without a bound
  or with `adaptive: false`.

  Once the sample holds `Sketch.sample_size(max_size)` requests (hits and
  misses as `on_access/2` and `on_write/5` count them), its hit rate is
  compared with the previous sample's: no worse keeps the window moving the
  way the last step went, worse reverses it. The step starts at 6.25% of
  `max_size` and decays by 0.98 per sample, and returns to 6.25% whenever
  the rate moved by 5 points or more. Then the adjustment is applied by
  `resize/2`; what it could not transfer is retried by the next call.
  """
  @spec climb(t()) :: t()
  def climb(%__MODULE__{climber: nil} = state), do: state

  def climb(%__MODULE__{} = state) do
    state = sample_done(state)
    resize(state, state.climber.adjustment)
  end

  # Caffeine's `determineAdjustment`: nothing until the sample is complete,
  # then the signed adjustment, the next step and a fresh sample.
  defp sample_done(%__MODULE__{sample_hits: hits, sample_misses: misses} = state) do
    %__MODULE__{max_size: max_size, climber: climber} = state
    requests = hits + misses

    if requests < Sketch.sample_size(max_size) do
      state
    else
      hit_rate = hits / requests
      change = hit_rate - climber.hit_rate
      amount = if change >= 0, do: climber.step, else: -climber.step

      step =
        cond do
          abs(change) < @restart_threshold -> @step_decay * amount
          amount >= 0 -> @step_percent * max_size
          true -> -@step_percent * max_size
        end

      %{
        state
        | sample_hits: 0,
          sample_misses: 0,
          climber: %{climber | hit_rate: hit_rate, step: step, adjustment: trunc(amount)}
      }
    end
  end

  @doc """
  Moves `amount` of weight from the main region's limits to the window's
  (positive) or back (negative), Caffeine's `increaseWindow` and
  `decreaseWindow`; `climb/1` calls it with the adjustment its samples
  decided, and tests call it directly. Adaptive bounded policies only.

  Growing takes the probation LRU entry while it fits in what is left of
  `amount`, else the protected LRU, to the window MRU; it lowers
  `protected_max` by the same amount and first demotes the protected LRU
  entries that no longer fit. Shrinking moves window LRU entries to the
  probation MRU and raises `protected_max`, never below a window limit of
  1. Either way the limits move by exactly the weight transferred, at most
  #{@transfer_cap} entries per call, and the rest stays in the climber's
  `adjustment` for the next call. The moved entries are not admission
  candidates, and the total weight is unchanged.
  """
  @spec resize(t(), integer()) :: t()
  def resize(%__MODULE__{climber: %{adjustment: 0}} = state, 0), do: state
  def resize(%__MODULE__{climber: %{}} = state, 0), do: put_adjustment(state, 0)

  def resize(%__MODULE__{climber: %{}} = state, amount) when amount > 0 do
    if state.protected_max == 0 do
      put_adjustment(state, amount)
    else
      quota = min(amount, state.protected_max)

      state =
        demote(%{
          state
          | protected_max: state.protected_max - quota,
            window_max: state.window_max + quota
        })

      {state, left} = transfer_in(state, quota, @transfer_cap)

      %{state | protected_max: state.protected_max + left, window_max: state.window_max - left}
      |> put_adjustment(left)
    end
  end

  def resize(%__MODULE__{climber: %{}} = state, amount) when amount < 0 do
    if state.window_max <= 1 do
      put_adjustment(state, amount)
    else
      quota = min(-amount, state.window_max - 1)

      state = %{
        state
        | protected_max: state.protected_max + quota,
          window_max: state.window_max - quota
      }

      {state, left} = transfer_out(state, quota, @transfer_cap)

      %{state | protected_max: state.protected_max - left, window_max: state.window_max + left}
      |> put_adjustment(-left)
    end
  end

  defp put_adjustment(%__MODULE__{climber: climber} = state, adjustment),
    do: %{state | climber: %{climber | adjustment: adjustment}}

  # Main → window MRU while the next main LRU entry fits in the quota.
  defp transfer_in(state, quota, 0), do: {state, quota}

  defp transfer_in(state, quota, n) do
    case main_lru(state, quota) do
      {segment, seq, key, weight} ->
        state
        |> move(key, segment, seq, :window)
        |> add_segment(segment, -weight)
        |> add_segment(:window, weight)
        |> transfer_in(quota - weight, n - 1)

      nil ->
        {state, quota}
    end
  end

  # The probation LRU when it fits in `quota`, else the protected LRU when
  # that fits, as Caffeine's `increaseWindow` picks.
  defp main_lru(state, quota) do
    with nil <- fitting_lru(state, :probation, quota),
         do: fitting_lru(state, :protected, quota)
  end

  defp fitting_lru(%__MODULE__{order: order, policy: policy}, segment, quota) do
    with {seq, key} <- lru_entry(order, segment),
         weight when weight <= quota <- :ets.lookup_element(policy, key, @row_weight) do
      {segment, seq, key, weight}
    else
      _ -> nil
    end
  end

  # Window LRU → probation MRU while the next one fits in the quota.
  defp transfer_out(state, quota, 0), do: {state, quota}

  defp transfer_out(state, quota, n) do
    case fitting_lru(state, :window, quota) do
      {:window, seq, key, weight} ->
        state
        |> move(key, :window, seq, :probation)
        |> add_segment(:window, -weight)
        |> add_segment(:probation, weight)
        |> transfer_out(quota - weight, n - 1)

      nil ->
        {state, quota}
    end
  end

  @doc """
  The climber's view, for `Theine.Maintenance.info/1` and tests: whether
  the window adapts, the current window and protected limits, and the hits
  and misses counted toward the sample in progress. `nil` without a bound.
  """
  @spec climber(t()) ::
          %{
            adaptive: boolean(),
            window_max: pos_integer(),
            protected_max: non_neg_integer(),
            sample_hits: non_neg_integer(),
            sample_misses: non_neg_integer()
          }
          | nil
  def climber(%__MODULE__{order: nil}), do: nil

  def climber(%__MODULE__{} = state) do
    %{
      adaptive: state.climber != nil,
      window_max: state.window_max,
      protected_max: state.protected_max,
      sample_hits: state.sample_hits,
      sample_misses: state.sample_misses
    }
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
    if state.order, do: true = :ets.delete(state.order, base(segment) + seq)
    add(state, -1, -weight)
    add_segment(state, segment, -weight)
  end

  @doc """
  Empties the tables, zeroes the published sizes and the segment weights,
  clears the sketch, and restarts the climber from the configured window
  (`Theine.clear/1`).
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = state) do
    true = :ets.delete_all_objects(state.policy)
    true = :ets.delete_all_objects(state.ids)
    if state.order, do: true = :ets.delete_all_objects(state.order)
    if state.sketch, do: :ok = Sketch.clear(state.sketch)
    publish(state, 0, 0)

    %{
      state
      | window_weight: 0,
        probation_weight: 0,
        protected_weight: 0,
        sketch_size: 0,
        candidates: 0,
        cursor: nil,
        candidate_floor: nil,
        sample_hits: 0,
        sample_misses: 0
    }
    |> restart_climber()
  end

  # An empty cache starts the climb over from the configured window, as a
  # new policy would.
  defp restart_climber(%__MODULE__{climber: nil} = state), do: state

  defp restart_climber(%__MODULE__{climber: climber, max_size: max_size} = state) do
    %{
      state
      | window_max: climber.window_max,
        protected_max: climber.protected_max,
        climber: %{climber | hit_rate: 0.0, step: -@step_percent * max_size, adjustment: 0}
    }
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
    end_of(lru_entry(order, segment))
  end

  @doc """
  The key at the MRU end of `segment`, or `:error` when the segment is
  empty. Bounded policies only.
  """
  @spec mru(t(), :window | :probation | :protected) :: {:ok, Entry.key()} | :error
  def mru(%__MODULE__{order: order}, segment) when not is_nil(order) do
    base = base(segment)

    case :ets.prev(order, base + @max_seq) do
      order_key when is_integer(order_key) and order_key > base ->
        {:ok, :ets.lookup_element(order, order_key, 2)}

      _ ->
        :error
    end
  end

  defp end_of({_seq, key}), do: {:ok, key}
  defp end_of(nil), do: :error

  # The `{seq, key}` at the LRU end of `segment`, or nil when it is empty.
  defp lru_entry(order, segment) do
    base = base(segment)

    case :ets.next(order, base) do
      order_key when is_integer(order_key) and order_key < base + @max_seq ->
        {order_key - base, :ets.lookup_element(order, order_key, 2)}

      _ ->
        nil
    end
  end

  @doc """
  The `order` key of `seq` in `segment`, for tests that check or arrange
  the table directly.

      iex> Theine.Policy.order_key(:probation, 1) == Theine.Policy.max_seq() + 1
      true
  """
  @spec order_key(:window | :probation | :protected, pos_integer()) :: pos_integer()
  def order_key(segment, seq) when is_integer(seq) and seq > 0 and seq < @max_seq,
    do: base(segment) + seq

  @compile {:inline, base: 1}
  defp base(:probation), do: @probation_base
  defp base(:protected), do: @protected_base
  defp base(:window), do: @window_base

  defp segment_of(order_key) do
    case order_key >>> @seq_bits do
      1 -> :probation
      2 -> :protected
      3 -> :window
    end
  end

  @doc "The weight held by each segment (zero everywhere without a bound)."
  @spec weights(t()) :: weights()
  def weights(%__MODULE__{} = state) do
    %{
      window: state.window_weight,
      probation: state.probation_weight,
      protected: state.protected_weight
    }
  end

  @doc """
  The `order` rows as `{{segment, seq}, key}`, the segments in the order
  probation, protected, window and LRU first within each (tests only).
  """
  @spec order_rows(t()) :: [{{segment(), pos_integer()}, Entry.key()}]
  def order_rows(%__MODULE__{order: nil}), do: []

  def order_rows(%__MODULE__{order: order}) do
    for {order_key, key} <- :ets.tab2list(order),
        do: {{segment_of(order_key), order_key &&& @seq_mask}, key}
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
