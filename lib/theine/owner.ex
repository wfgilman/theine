defmodule Theine.Owner do
  @moduledoc """
  Holds the entries table, the atomics and the counters of one cache
  (specs/08 §Supervision tree, specs/01 §Tables and handles).

  `init/1` creates the public entries table, allocates the `ids`, `pending`
  and `flags` atomics and the stats counters, and writes the completed
  `%Theine.Config{}` to `:persistent_term`. After that the process does
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

  alias Theine.Config

  @table_options [
    :set,
    :public,
    :named_table,
    read_concurrency: true,
    write_concurrency: :auto,
    decentralized_counters: true
  ]

  # Index of the drain flag inside the `flags` atomics (specs/03).
  @drain_flag 1

  # :counters fields (specs/08 §Stats); Theine.Stats names them in M1.6.
  @counter_fields 7

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

    config =
      case :persistent_term.get(Config.key(config.name), nil) do
        %Config{} = existing ->
          if Config.same_options?(existing, config), do: existing, else: store(allocate(config))

        nil ->
          store(allocate(config))
      end

    {:ok, config}
  end

  @impl true
  def terminate(_reason, %Config{name: name}) do
    :persistent_term.erase(Config.key(name))
    :ok
  end

  defp allocate(%Config{} = config) do
    %{
      config
      | ids: :atomics.new(1, signed: false),
        pending: :atomics.new(1, signed: true),
        flags: :atomics.new(@drain_flag, signed: false),
        counters: :counters.new(@counter_fields, [:write_concurrency])
    }
  end

  defp store(%Config{name: name} = config) do
    :persistent_term.put(Config.key(name), config)
    config
  end
end
