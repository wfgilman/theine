defmodule Theine.Bench.Cache do
  @moduledoc """
  The `theine` policy of `mix bench hitrate` (specs/09 §`mix bench hitrate`):
  a real bounded cache replayed synchronously, so that a trace gives the
  same hit count on every run.

  Every access is a `Theine.get/2`; a miss is followed by a `Theine.put/3`
  of the key, as Caffeine's simulator does. After every `accesses_per_pass/0`
  accesses (an option; the default is the specs/08 default `drain_threshold`)
  the harness runs one maintenance pass with `Theine.run_maintenance/1`,
  and those are the only passes that run (specs/09 §Decisions M2.10): the
  cache is started with the reader's drain trigger out of reach
  (`drain_threshold` 2^30, above any trace length) and the interval timer a
  day away, and the pass count is checked in `close/1`. The write-count and
  follow-up triggers cannot fire with at most 64 accesses per pass
  (`write_batch` 256, `read_buffer_slots` 64, `evict_batch` 1024).
  The maintenance process applies each write as it arrives, with the
  eviction it forces (specs/04 §The pass, M2.11c), and a miss's put is
  followed by a `Theine.Maintenance.info/1` round trip, so that the put and
  its eviction are done before the next access: left to the scheduler, an
  eviction lands before or after the batch's next gets depending on when
  the maintenance process runs, and a key it removes hits in one run and
  misses in the next (measured in M2.11e: 15_298 hits with every eviction
  before the next get, 15_279 with every eviction after the batch, on the
  key sequence of theine_test's replay test). The reads sit in the ring
  until the pass drains them, so every pass sees the batch's writes with
  their evictions, then its reads. The ring has a single stripe
  (`stripes: 1`): with one per scheduler, the reads of a batch would be
  spread over the stripes as the replaying process migrates and the pass,
  which drains stripe by stripe, would apply them in an order that differs
  from run to run (measured in M2.10: about 0.02% of OLTP's hits moved
  between two runs). The admission guard's `:rand` is
  seeded from the cache name, which is derived from the trace, the size and
  the window percentage, so it draws the same numbers every run.

  The maintenance process still runs the production code: the hit path, the
  ring, the policy, the sketch and its aging are those of `lib/`.
  """

  import Bitwise

  # The specs/08 default `drain_threshold`: how many accesses one pass covers.
  @accesses_per_pass 32

  # Out of reach of every trace (DS1 is 43.7 M requests), and a day.
  @drain_threshold 1 <<< 30
  @maintenance_interval 86_400_000

  # Measured (M2.10): 378 B of ETS per entry at max_size 1_000_000, entries
  # table and policy tables together, with small keys and an atom value.
  @bytes_per_entry 400

  # The ring keeps the last `read_buffer_slots` (64) reads of a stripe and
  # `write_batch` (256) applied events trigger a pass of their own, so a
  # batch must stay within the ring.
  @max_accesses_per_pass 64

  @enforce_keys [:name, :sup, :max_size, :batch]
  defstruct [:name, :sup, :max_size, :batch, accesses: 0, hits: 0, passes: 0]

  @type t :: %__MODULE__{
          name: atom(),
          sup: pid(),
          max_size: pos_integer(),
          batch: pos_integer(),
          accesses: non_neg_integer(),
          hits: non_neg_integer(),
          passes: non_neg_integer()
        }

  @doc "The default number of accesses between two synchronous passes."
  @spec accesses_per_pass() :: 32
  def accesses_per_pass, do: @accesses_per_pass

  @doc "The largest number of accesses one pass may cover."
  @spec max_accesses_per_pass() :: 64
  def max_accesses_per_pass, do: @max_accesses_per_pass

  @doc "Estimated ETS bytes per entry, for the harness's memory budget."
  @spec bytes_per_entry() :: 400
  def bytes_per_entry, do: @bytes_per_entry

  @doc """
  Starts a cache bounded at `size` entries for `trace`. Options:
  `window_percent` (default 1, the specs/05 default) and
  `accesses_per_pass` (default `accesses_per_pass/0`, at most
  `max_accesses_per_pass/0`; 1 replays every access synchronously, as
  Caffeine's simulator does).
  """
  @spec new(String.t(), pos_integer(), keyword()) :: %__MODULE__{
          name: atom(),
          sup: pid(),
          max_size: pos_integer(),
          batch: 1..64,
          accesses: 0,
          hits: 0,
          passes: 0
        }
  def new(trace, size, opts \\ []) when is_binary(trace) and is_integer(size) and size > 0 do
    window_percent = Keyword.get(opts, :window_percent, 1)
    batch = Keyword.get(opts, :accesses_per_pass, @accesses_per_pass)

    unless is_integer(batch) and batch in 1..@max_accesses_per_pass do
      raise ArgumentError, "accesses_per_pass must be in 1..#{@max_accesses_per_pass}"
    end

    name = :"theine_hitrate_#{trace}_#{size}_w#{window_percent}"

    {:ok, sup} =
      Theine.start_link(
        name: name,
        max_size: size,
        window_percent: window_percent,
        stripes: 1,
        drain_threshold: @drain_threshold,
        maintenance_interval: @maintenance_interval
      )

    %__MODULE__{name: name, sup: sup, max_size: size, batch: batch}
  end

  @doc "Records one access; returns whether it hit and the updated state."
  @spec access(t(), term()) :: {:hit | :miss, t()}
  def access(%__MODULE__{name: name} = cache, key) do
    {outcome, hits} =
      case Theine.get(name, key) do
        {:ok, _} ->
          {:hit, cache.hits + 1}

        :error ->
          :ok = Theine.put(name, key, :v)
          _ = Theine.Maintenance.info(name)
          {:miss, cache.hits}
      end

    accesses = cache.accesses + 1

    if rem(accesses, cache.batch) == 0 do
      :ok = Theine.run_maintenance(name)
      {outcome, %{cache | accesses: accesses, hits: hits, passes: cache.passes + 1}}
    else
      {outcome, %{cache | accesses: accesses, hits: hits}}
    end
  end

  @doc """
  Runs the last pass, checks that the replay was the synchronous one this
  module promises, and stops the cache. Raises when the maintenance process
  ran a pass of its own, when the cache's own hit count (specs/03 §Hits from
  the tails) differs from the replay's, or when the cache is over its bound
  after the last pass.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{name: name, sup: sup} = cache) do
    :ok = Theine.run_maintenance(name)
    passes = cache.passes + 1

    %{passes: seen, pending: pending} = Theine.Maintenance.info(name)
    %Theine.Stats{hits: counted} = Theine.stats(name)
    size = Theine.size(name)

    problems =
      [
        {seen != passes, "#{seen} maintenance passes ran, the replay called #{passes}"},
        {pending != 0, "#{pending} write events pending after the last pass"},
        {counted != cache.hits, "the cache counted #{counted} hits, the replay #{cache.hits}"},
        {size > cache.max_size, "#{size} entries resident, max_size #{cache.max_size}"}
      ]
      |> Enum.filter(fn {bad?, _} -> bad? end)
      |> Enum.map(fn {_, message} -> message end)

    :ok = Supervisor.stop(sup)

    if problems != [] do
      raise "mix bench hitrate: #{name} was not replayed deterministically: " <>
              Enum.join(problems, "; ")
    end

    :ok
  end
end
