defmodule Theine.Stats do
  @moduledoc """
  Cache statistics (specs/08 §Stats).

  Each cache owns one `:counters` reference with `write_concurrency`, holding
  the fields below in this order. The indices are fixed here and read by
  `Theine.get/2` and `Theine.Entry` as compile-time constants, so the hot
  path pays no call into this module.

  | index | field |
  |---|---|
  | 1 | `hits` |
  | 2 | `misses` |
  | 3 | `loads` |
  | 4 | `load_failures` |
  | 5 | `evictions` |
  | 6 | `expirations` |
  | 7 | `refreshes` |

  `hits` is special. A bounded cache never increments its `hits` counter:
  every hit claims a sequence number in its read-buffer stripe, so the sum
  of the stripe tails is already the exact hit count (specs/03 §Hits from
  the tails) and `read/1` reports that sum. An unbounded cache has no read
  buffer and counts hits with the counter.

  `stats: false` (specs/08 §Stats) turns off the request counters: `hits`
  and `misses` are not counted on `get/2`, which saves the counter op on an
  unbounded hit and on a miss. The event counters (`expirations`,
  `evictions`, `loads`, `load_failures`, `refreshes`) are maintained
  regardless; they are incremented off the hot path, where the cost is
  nothing, and stay useful for operators (specs/08 §Decisions).
  """

  alias Theine.Config

  @fields [:hits, :misses, :loads, :load_failures, :evictions, :expirations, :refreshes]

  @type t :: %__MODULE__{
          hits: non_neg_integer(),
          misses: non_neg_integer(),
          loads: non_neg_integer(),
          load_failures: non_neg_integer(),
          evictions: non_neg_integer(),
          expirations: non_neg_integer(),
          refreshes: non_neg_integer(),
          hit_rate: float()
        }

  @type field ::
          :hits | :misses | :loads | :load_failures | :evictions | :expirations | :refreshes

  defstruct hits: 0,
            misses: 0,
            loads: 0,
            load_failures: 0,
            evictions: 0,
            expirations: 0,
            refreshes: 0,
            hit_rate: 0.0

  @doc "The counter fields in index order."
  @spec fields() :: [field(), ...]
  def fields, do: @fields

  @doc "Number of counter fields; `Theine.Owner` sizes the `:counters` with it."
  @spec field_count() :: 7
  def field_count, do: length(@fields)

  @doc "Index of the `hits` counter."
  @spec hits() :: 1
  def hits, do: 1

  @doc "Index of the `misses` counter."
  @spec misses() :: 2
  def misses, do: 2

  @doc "Index of the `loads` counter."
  @spec loads() :: 3
  def loads, do: 3

  @doc "Index of the `load_failures` counter."
  @spec load_failures() :: 4
  def load_failures, do: 4

  @doc "Index of the `evictions` counter."
  @spec evictions() :: 5
  def evictions, do: 5

  @doc "Index of the `expirations` counter."
  @spec expirations() :: 6
  def expirations, do: 6

  @doc "Index of the `refreshes` counter."
  @spec refreshes() :: 7
  def refreshes, do: 7

  @doc """
  Index of `field` in the counters.

      iex> Theine.Stats.index(:evictions)
      5
  """
  @spec index(field()) :: 1..7
  def index(field) when field in @fields do
    Enum.find_index(@fields, &(&1 == field)) + 1
  end

  @doc """
  Reads the counters of a cache into a `%Theine.Stats{}`.

  `hit_rate` is `hits / (hits + misses)`, or `0.0` when neither has been
  counted. `hits` comes from the read-buffer tails when the config has a
  read buffer (a bounded cache), else from the `hits` counter.

      iex> {:ok, _} = Theine.start_link(name: :stats_read_doc, max_size: :infinity)
      iex> Theine.put(:stats_read_doc, :a, 1)
      iex> Theine.get(:stats_read_doc, :a)
      iex> Theine.get(:stats_read_doc, :b)
      iex> Theine.Stats.read(Theine.Config.get(:stats_read_doc))
      %Theine.Stats{hits: 1, misses: 1, hit_rate: 0.5}
  """
  @spec read(Config.t()) :: t()
  def read(%Config{counters: counters} = config) do
    hits = hits(config)
    misses = :counters.get(counters, misses())

    %__MODULE__{
      hits: hits,
      misses: misses,
      loads: :counters.get(counters, loads()),
      load_failures: :counters.get(counters, load_failures()),
      evictions: :counters.get(counters, evictions()),
      expirations: :counters.get(counters, expirations()),
      refreshes: :counters.get(counters, refreshes()),
      hit_rate: hit_rate(hits, misses)
    }
  end

  @doc """
  The hit count of a cache: the `hits` counter in an unbounded cache, the
  sum of the read-buffer stripe tails in a bounded one (specs/03 §Hits from
  the tails).
  """
  @spec hits(Config.t()) :: non_neg_integer()
  def hits(%Config{read_buffer: nil, counters: counters}), do: :counters.get(counters, hits())

  def hits(%Config{read_buffer: buffer, stripes: stripes, read_buffer_slots: slots}) do
    # Stripe `s` starts at `s * (2 + slots) + 1` and its tail is the first
    # word (specs/03 §Layout). Theine.ReadBuffer owns this layout; the sum
    # is computed here so that stats/1 needs nothing from the policy.
    width = 2 + slots

    Enum.reduce(0..(stripes - 1)//1, 0, fn s, sum ->
      sum + :atomics.get(buffer, s * width + 1)
    end)
  end

  @doc """
  Hit rate as a float: `hits / (hits + misses)`, or `0.0` with no requests.

      iex> Theine.Stats.hit_rate(3, 1)
      0.75
      iex> Theine.Stats.hit_rate(0, 0)
      0.0
  """
  @spec hit_rate(non_neg_integer(), non_neg_integer()) :: float()
  def hit_rate(0, 0), do: 0.0
  def hit_rate(hits, misses), do: hits / (hits + misses)
end
