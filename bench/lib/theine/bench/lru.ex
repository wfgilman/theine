defmodule Theine.Bench.LRU do
  @moduledoc """
  The reference LRU for `mix bench hitrate` (specs/09: "any correct
  implementation; it is a baseline, not a product").

  Two private ETS tables owned by the calling process: `keys` maps a key to
  its last-access sequence number and `order` (an ordered set) maps the
  sequence number back to the key, so the least recently used key is
  `:ets.first(order)`. Every entry has weight 1, matching the trace replay.
  """

  @enforce_keys [:capacity, :keys, :order]
  defstruct [:capacity, :keys, :order, size: 0, seq: 0]

  @type t :: %__MODULE__{
          capacity: pos_integer(),
          keys: :ets.tid(),
          order: :ets.tid(),
          size: non_neg_integer(),
          seq: non_neg_integer()
        }

  # Measured (M2.10): 144 B of ETS per entry at 1_000_000 entries.
  @bytes_per_entry 160

  @doc "Estimated ETS bytes per entry, for the harness's memory budget."
  @spec bytes_per_entry() :: 160
  def bytes_per_entry, do: @bytes_per_entry

  @spec new(pos_integer()) :: t()
  def new(capacity) when is_integer(capacity) and capacity > 0 do
    %__MODULE__{
      capacity: capacity,
      keys: :ets.new(:bench_lru_keys, [:set, :private]),
      order: :ets.new(:bench_lru_order, [:ordered_set, :private])
    }
  end

  @doc "Records one access; returns whether it hit and the updated state."
  @spec access(t(), term()) :: {:hit | :miss, t()}
  def access(%__MODULE__{keys: keys, order: order, seq: seq} = lru, key) do
    seq = seq + 1

    case :ets.lookup(keys, key) do
      [{_, old}] ->
        :ets.delete(order, old)
        :ets.insert(order, {seq, key})
        :ets.insert(keys, {key, seq})
        {:hit, %{lru | seq: seq}}

      [] ->
        size =
          if lru.size == lru.capacity do
            lru_seq = :ets.first(order)
            [{_, victim}] = :ets.take(order, lru_seq)
            :ets.delete(keys, victim)
            lru.size
          else
            lru.size + 1
          end

        :ets.insert(order, {seq, key})
        :ets.insert(keys, {key, seq})
        {:miss, %{lru | seq: seq, size: size}}
    end
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{keys: keys, order: order}) do
    :ets.delete(keys)
    :ets.delete(order)
    :ok
  end
end
