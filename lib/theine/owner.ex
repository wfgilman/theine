defmodule Theine.Owner do
  @moduledoc """
  Holds the entries table, the atomics and the counters of one cache
  (specs/08 §Supervision tree, specs/01 §Tables and handles).

  `init/1` creates the public entries table and the loader's `inflight`,
  `waiters` and `refreshing` tables (specs/07), allocates the `ids`, `pending`,
  `flags` and `sizes` atomics and the stats counters, plus the read buffer
  (specs/03) and the frequency sketch (specs/02) when the cache is bounded,
  and writes the completed `%Theine.Config{}` to `:persistent_term`. An
  unbounded cache (`max_size: :infinity`) allocates neither, so its hits
  never touch `:atomics` (specs/08 §Acceptance). After that the process does
  nothing but hold the table, so it never crashes on its own; if it is
  killed, the `rest_for_one` supervisor restarts it together with the task
  supervisor and the maintenance process, and the cache comes back empty.

  The `:persistent_term` entry is written once per cache lifetime: a
  restarted Owner under the same options keeps the atomics and counters the
  term already holds (they live as long as the term references them) and
  only recreates the table. `terminate/2` erases the term, so stopping the
  cache leaves nothing behind.
  """

  use GenServer

  alias Theine.{Config, ReadBuffer, Sketch}

  @table_options [
    :set,
    :public,
    :named_table,
    read_concurrency: true,
    write_concurrency: :auto,
    decentralized_counters: true
  ]

  # The tables of Theine.Loader (specs/07 §Single-flight, §Refresh-after-
  # write): `inflight` a set of claims, `waiters` a duplicate bag of waiter
  # rows, `refreshing` a set of running refreshes. All three are empty
  # whenever no load is in progress.
  @loader_table_options [:public, :named_table, write_concurrency: :auto]

  # Index of the drain flag inside the `flags` atomics (specs/03).
  @drain_flag 1

  # :counters fields (specs/08 §Stats), named by Theine.Stats.
  @counter_fields Theine.Stats.field_count()

  # `sizes` atomics: entry count and weighted size, maintained by the
  # maintenance process (Theine.Policy) and read by size/1 and weighted_size/1.
  @size_fields 2

  @doc "Registered name of the owner process of `cache`."
  @spec name(Config.cache()) :: atom()
  def name(cache) when is_atom(cache), do: Module.concat(__MODULE__, cache)

  @doc "Index of the drain flag in `config.flags`."
  @spec drain_flag() :: 1
  def drain_flag, do: @drain_flag

  @doc false
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: name(config.name))
  end

  @impl true
  def init(%Config{} = config) do
    # Trap exits so a supervisor shutdown runs terminate/2 and erases the term.
    Process.flag(:trap_exit, true)
    _ = :ets.new(config.table, @table_options)
    _ = :ets.new(config.inflight, [:set | @loader_table_options])
    _ = :ets.new(config.waiters, [:duplicate_bag | @loader_table_options])
    _ = :ets.new(config.refreshing, [:set | @loader_table_options])

    config =
      case :persistent_term.get(Config.key(config.name), nil) do
        %Config{} = existing ->
          if Config.same_options?(existing, config), do: existing, else: store(allocate(config))

        nil ->
          store(allocate(config))

        other ->
          # The config is keyed by the bare cache name (specs/01 §Decisions),
          # so another library's term under that atom would be overwritten.
          raise ArgumentError,
                "cannot start cache #{inspect(config.name)}: :persistent_term key " <>
                  "#{inspect(config.name)} already holds #{inspect(other, limit: 5)}"
      end

    {:ok, config}
  end

  @impl true
  def terminate(_reason, %Config{name: name}) do
    :persistent_term.erase(Config.key(name))
    :ok
  end

  defp allocate(%Config{stats: stats} = config) do
    counters = :counters.new(@counter_fields, [:write_concurrency])
    bounded? = is_integer(config.max_size)
    # The miss path counts through this field only, so `stats: false` is
    # one nil match there (specs/08 §Stats).
    request_counters = if(stats, do: counters, else: nil)

    read_buffer =
      if(bounded?, do: ReadBuffer.new(config.stripes, config.read_buffer_slots), else: nil)

    hit =
      if(bounded?,
        do:
          {read_buffer, config.stripes - 1, 2 + config.read_buffer_slots,
           config.read_buffer_slots - 1, config.drain_threshold - 1},
        else: request_counters
      )

    %{
      config
      | ids: :atomics.new(1, signed: false),
        pending: :atomics.new(1, signed: true),
        flags: :atomics.new(@drain_flag, signed: false),
        counters: counters,
        request_counters: request_counters,
        # The hit path fetches this one key: the read-buffer tuple when
        # bounded, else the request counters (specs/08 §Decisions M2.8).
        # The sizes are precomputed as the stripe mask, the stripe width,
        # the slot mask and the trigger mask (specs/03 §Decisions M2.8b).
        # A hit that may start a refresh is tagged, so that no other cache
        # pays for the check (specs/07 §Decisions M4.4).
        hit: refresh_hit(config, hit),
        sizes: :atomics.new(@size_fields, signed: true),
        read_buffer: read_buffer,
        sketch: if(bounded?, do: Sketch.new(config.max_size), else: nil)
    }
  end

  # `get/2` can refresh only with the cache's loader, so a cache without one
  # keeps the plain hit; `fetch/4` checks the age itself (Theine.Loader).
  defp refresh_hit(%Config{refresh_after_write: ms, loader: loader}, hit)
       when is_integer(ms) and is_function(loader, 1),
       do: {:refresh, ms, hit}

  defp refresh_hit(%Config{}, hit), do: hit

  defp store(%Config{name: name} = config) do
    :persistent_term.put(Config.key(name), config)
    config
  end
end
