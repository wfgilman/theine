defmodule Theine.ReadBuffer do
  @moduledoc """
  Striped, lossy ring buffers of entry ids over one `:atomics` array:
  Caffeine's `StripedBuffer` of `BoundedBuffer`s (specs/03 §Read buffer).

  A hit records the id of the entry it read; the maintenance process drains
  the ids into the policy. When a stripe is full the access is dropped, never
  blocked on: the policy only needs a representative sample of reads.

  Layout: `stripes` contiguous regions of `2 + slots` unsigned words. For
  stripe `s` (0-based), with `base = s * (2 + slots) + 1`:

      base          tail   next sequence number to claim, monotonically increasing
      base + 1      head   next sequence number the drainer will read
      base + 2 ..   slots  ring of ids, slot `rem(seq, slots)`; 0 means empty

  Every call to `record/2` claims a sequence from its stripe's tail and
  writes its id into slot `rem(seq, slots)`, so the ring always holds the
  most recent `slots` reads and a reader never looks at the head: an
  undrained read is overwritten (dropped) rather than refused (specs/03
  §Decisions M2.8b). The sum of the tails is the exact number of hits
  recorded since the array was created (§Hits from the tails);
  `Theine.Stats` reads it through `hits/1`. The tails are never reset.
  `tail - head` of a stripe is how far behind the drainer is (`lag/1`).

  Only the maintenance process moves heads (`drain/3`, `reset_heads/1`). It
  is the sole consumer, so heads need no compare-exchange, and it clears the
  drain flag before draining so that readers can schedule the next pass
  while one runs (specs/04 §The pass step 2).

  `record/2` is the reference implementation of the hot-path side;
  `Theine.get/2` carries a copy of its body. Readers that claimed a sequence
  but have not yet written their slot, drains that race them, and readers
  overwriting a slot the drainer is visiting cost a lost or duplicated
  sample and nothing else.
  """

  alias Theine.Config

  # Index of the drain flag inside `config.flags` (specs/03).
  @drain_flag Theine.Owner.drain_flag()

  @typedoc "An entry id as stored in the entries table; never 0."
  @type id :: pos_integer()

  @typedoc """
  The result of a drain: the accumulator, the number of ids handed to the
  function, and whether some stripe was full (`tail - head >= slots`) when it
  was drained, in which case the maintenance process schedules a follow-up
  pass (specs/04 §The pass).
  """
  @type drained(acc) :: {acc, reads :: non_neg_integer(), full? :: boolean()}

  @typedoc "One stripe as `dump/1` reports it."
  @type stripe :: %{tail: non_neg_integer(), head: non_neg_integer(), ids: [non_neg_integer()]}

  @doc """
  Allocates a zeroed array for `stripes` stripes of `slots` slots each.

      iex> buffer = Theine.ReadBuffer.new(2, 4)
      iex> :atomics.info(buffer).size
      12
  """
  @spec new(pos_integer(), pos_integer()) :: :atomics.atomics_ref()
  def new(stripes, slots)
      when is_integer(stripes) and stripes > 0 and is_integer(slots) and slots > 0 do
    :atomics.new(stripes * (2 + slots), signed: false)
  end

  @doc """
  Records a read of entry `id` in the stripe of the current scheduler
  (specs/03 §`record/2`).

  Claims a sequence `t` with one `add_get` on the stripe's tail and writes
  `id` into slot `rem(t, slots)` with one `put`, whatever the head says: an
  undrained read in that slot is overwritten, which is the drop. Calls
  `schedule_drain/1` on every `drain_threshold`-th sequence of the stripe
  (`rem(t + 1, drain_threshold) == 0`), so the drain flag is tested once per
  `drain_threshold` reads per stripe rather than on every read past it.
  `stripes`, `slots` and `drain_threshold` are powers of two
  (`Theine.Config`), so every `rem` is a mask. Never blocks, never loops,
  never raises on the way to the maintenance process. Returns `:ok`.

  Cost on the common hit: one scheduler-id read, one `add_get`, one `put`;
  once per `drain_threshold` reads one `compare_exchange` and one `send` on
  top.
  """
  @spec record(Config.t(), id()) :: :ok
  def record(
        %{
          read_buffer: buffer,
          stripes: stripes,
          read_buffer_slots: slots,
          drain_threshold: threshold
        } = config,
        id
      ) do
    base = Bitwise.band(:erlang.system_info(:scheduler_id) - 1, stripes - 1) * (2 + slots) + 1
    n = :atomics.add_get(buffer, base, 1)
    :atomics.put(buffer, base + 2 + Bitwise.band(n - 1, slots - 1), id)
    if Bitwise.band(n, threshold - 1) == 0, do: schedule_drain(config), else: :ok
  end

  @doc """
  Asks the maintenance process for a pass, at most once until it starts one:
  flips the drain flag from 0 to 1 with one `compare_exchange` and, on
  success, sends `:drain` to the registered maintenance name. The
  maintenance process clears the flag when it starts a drain (specs/04 §The
  pass step 2), so a trigger during a pass schedules the next one.

  Never raises: if the name is not registered (the process is restarting),
  the message is dropped and the flag stays set. The restarted
  `Theine.Maintenance` process resets the flag and schedules its own pass when the rebuilt cache is over
  capacity (specs/04 §Restart semantics), so nothing is owed to the reader.
  Returns `:ok`.
  """
  @spec schedule_drain(Config.t()) :: :ok
  def schedule_drain(%{flags: flags, maintenance: maintenance}) do
    case :atomics.compare_exchange(flags, @drain_flag, 0, 1) do
      :ok ->
        try do
          send(maintenance, :drain)
          :ok
        rescue
          ArgumentError -> :ok
        end

      _set ->
        :ok
    end
  end

  @doc """
  Drains every stripe, calling `fun.(id)` for each live id, and returns the
  number of ids drained and whether a stripe was full (specs/03 §`drain/2`).
  `drain/3` is the folding form the maintenance process uses.
  """
  @spec drain(Config.t(), (id() -> term())) :: {reads :: non_neg_integer(), full? :: boolean()}
  def drain(%{} = config, fun) when is_function(fun, 1) do
    {nil, reads, full?} =
      drain(config, nil, fn id, nil ->
        fun.(id)
        nil
      end)

    {reads, full?}
  end

  @doc """
  Drains every stripe into `acc` with `fun.(id, acc)`.

  For each stripe: reads `head` and `tail`, visits the sequences from
  `max(head, tail - slots)` to `tail - 1` (so at most `slots` per stripe),
  calls `fun` for every slot that is not 0, then moves `head` to the `tail`
  it read. Slots are not zeroed; sequence arithmetic alone decides what is
  live. A stripe counts as full when `tail - head >= slots` at the time it
  is read: the ring reached its capacity since the last drain, and every
  read past that overwrote an undrained one.

  Only the maintenance process may call this.
  """
  @spec drain(Config.t(), acc, (id(), acc -> acc)) :: drained(acc) when acc: term()
  def drain(%{read_buffer: buffer, stripes: stripes, read_buffer_slots: slots}, acc, fun)
      when is_function(fun, 2) do
    drain_stripes(buffer, 0, stripes, 2 + slots, slots, fun, {acc, 0, false})
  end

  @doc """
  Moves every head up to its tail without visiting the slots: a restarted
  maintenance process starts from the present rather than replaying reads
  of a policy it no longer has (specs/04 §Restart semantics). Returns `:ok`.
  """
  @spec reset_heads(Config.t()) :: :ok
  def reset_heads(%{read_buffer: buffer, stripes: stripes, read_buffer_slots: slots}) do
    width = 2 + slots

    for s <- 0..(stripes - 1)//1 do
      base = s * width + 1
      :atomics.put(buffer, base + 1, :atomics.get(buffer, base))
    end

    :ok
  end

  @doc """
  The number of reads recorded since the array was created, dropped or not:
  the sum of the stripe tails (specs/03 §Hits from the tails). This is the
  hit count of a bounded cache.
  """
  @spec hits(Config.t()) :: non_neg_integer()
  def hits(%{read_buffer: buffer, stripes: stripes, read_buffer_slots: slots}) do
    width = 2 + slots

    Enum.reduce(0..(stripes - 1)//1, 0, fn s, sum ->
      sum + :atomics.get(buffer, s * width + 1)
    end)
  end

  @doc """
  How far the drainer is behind: the sum over stripes of `tail - head`.
  Counts dropped reads too, so it can exceed `stripes * slots`.
  """
  @spec lag(Config.t()) :: non_neg_integer()
  def lag(%{read_buffer: buffer, stripes: stripes, read_buffer_slots: slots}) do
    width = 2 + slots

    Enum.reduce(0..(stripes - 1)//1, 0, fn s, sum ->
      base = s * width + 1
      sum + :atomics.get(buffer, base) - :atomics.get(buffer, base + 1)
    end)
  end

  @doc "The stripe of the scheduler with id `scheduler_id` (1-based), 0-based."
  @spec stripe_of(pos_integer(), pos_integer()) :: non_neg_integer()
  def stripe_of(scheduler_id, stripes)
      when is_integer(scheduler_id) and scheduler_id >= 1 and is_integer(stripes) and stripes > 0 do
    rem(scheduler_id - 1, stripes)
  end

  @doc "Every stripe's tail, head and ring contents, for tests and `info/1`."
  @spec dump(Config.t()) :: [stripe()]
  def dump(%{read_buffer: buffer, stripes: stripes, read_buffer_slots: slots}) do
    width = 2 + slots

    for s <- 0..(stripes - 1)//1 do
      base = s * width + 1

      %{
        tail: :atomics.get(buffer, base),
        head: :atomics.get(buffer, base + 1),
        ids: for(i <- 0..(slots - 1)//1, do: :atomics.get(buffer, base + 2 + i))
      }
    end
  end

  defp drain_stripes(_buffer, s, stripes, _width, _slots, _fun, result) when s >= stripes,
    do: result

  defp drain_stripes(buffer, s, stripes, width, slots, fun, {acc, reads, full?}) do
    base = s * width + 1
    head = :atomics.get(buffer, base + 1)
    tail = :atomics.get(buffer, base)
    first = max(head, tail - slots)
    {acc, reads} = drain_slots(buffer, base, slots, first, tail, fun, acc, reads)
    :atomics.put(buffer, base + 1, tail)

    drain_stripes(
      buffer,
      s + 1,
      stripes,
      width,
      slots,
      fun,
      {acc, reads, full? or tail - head >= slots}
    )
  end

  defp drain_slots(_buffer, _base, _slots, seq, tail, _fun, acc, reads) when seq >= tail,
    do: {acc, reads}

  defp drain_slots(buffer, base, slots, seq, tail, fun, acc, reads) do
    case :atomics.get(buffer, base + 2 + rem(seq, slots)) do
      0 -> drain_slots(buffer, base, slots, seq + 1, tail, fun, acc, reads)
      id -> drain_slots(buffer, base, slots, seq + 1, tail, fun, fun.(id, acc), reads + 1)
    end
  end
end
