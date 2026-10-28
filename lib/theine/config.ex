defmodule Theine.Config do
  @moduledoc """
  Resolved configuration of one cache (specs/08 §Starting a cache).

  Built once by `new!/1` from the `Theine.start_link/1` options, completed
  with the runtime handles (atomics, counters) by `Theine.Owner`, and stored
  in `:persistent_term` under the cache name itself. Every public call reads
  it with one `:persistent_term.get/1`; nothing rewrites it while the cache
  runs (specs/01 §Tables and handles). The key is the bare atom because
  hashing a `{Theine, name}` tuple costs more than the hit-path budget
  allows (specs/01 §Decisions); `Theine.Owner` refuses to start when that
  atom already holds a term that is not a cache config.

  Registered names are atoms derived from the cache name
  (`Theine.Maintenance.my_cache`), because write events are delivered with
  `send/2`, which needs a local atom name (specs/08 §Decisions).
  """

  @type cache :: atom()
  @type ms_or_infinity :: pos_integer() | :infinity

  @type t :: %__MODULE__{
          name: cache(),
          max_size: pos_integer() | :infinity,
          weigher: (term(), term() -> pos_integer()) | nil,
          expire_after_write: ms_or_infinity(),
          refresh_after_write: ms_or_infinity(),
          loader: (term() -> term()) | nil,
          window_percent: 1..80,
          adaptive: boolean(),
          stripes: pos_integer(),
          read_buffer_slots: pos_integer(),
          drain_threshold: pos_integer(),
          write_hwm: pos_integer(),
          write_batch: pos_integer(),
          expire_batch: pos_integer(),
          evict_batch: pos_integer(),
          maintenance_interval: pos_integer(),
          stats: boolean(),
          test_hooks: boolean(),
          table: cache(),
          maintenance: atom(),
          task_supervisor: atom(),
          ids: :atomics.atomics_ref() | nil,
          pending: :atomics.atomics_ref() | nil,
          flags: :atomics.atomics_ref() | nil,
          counters: :counters.counters_ref() | nil,
          request_counters: :counters.counters_ref() | nil,
          sizes: :atomics.atomics_ref() | nil,
          read_buffer: :atomics.atomics_ref() | nil,
          sketch: Theine.Sketch.t() | nil
        }

  @enforce_keys [:name, :max_size, :table, :maintenance, :task_supervisor]
  defstruct name: nil,
            max_size: :infinity,
            weigher: nil,
            expire_after_write: :infinity,
            refresh_after_write: :infinity,
            loader: nil,
            window_percent: 1,
            adaptive: false,
            stripes: nil,
            read_buffer_slots: 64,
            drain_threshold: 32,
            write_hwm: 1024,
            write_batch: 256,
            expire_batch: 1024,
            evict_batch: 1024,
            maintenance_interval: 1000,
            stats: true,
            test_hooks: false,
            table: nil,
            maintenance: nil,
            task_supervisor: nil,
            ids: nil,
            pending: nil,
            flags: nil,
            counters: nil,
            request_counters: nil,
            sizes: nil,
            read_buffer: nil,
            sketch: nil

  @options [
    :name,
    :max_size,
    :weigher,
    :expire_after_write,
    :refresh_after_write,
    :loader,
    :window_percent,
    :adaptive,
    :stripes,
    :read_buffer_slots,
    :drain_threshold,
    :write_hwm,
    :write_batch,
    :expire_batch,
    :evict_batch,
    :maintenance_interval,
    :stats,
    :test_hooks
  ]

  # Fields filled in by Theine.Owner, not by options. `request_counters` is
  # the same ref as `counters`, or nil with `stats: false`, so that the hit
  # path decides with one map key (specs/08 §Stats, §Decisions M1.6).
  @runtime_fields [
    :ids,
    :pending,
    :flags,
    :counters,
    :request_counters,
    :sizes,
    :read_buffer,
    :sketch
  ]

  @doc "The `start_link/1` option names, in the order of the specs/08 table."
  @spec options() :: [atom(), ...]
  def options, do: @options

  @doc """
  Validates `opts` and returns a config with the runtime handles unset.

  Raises `ArgumentError` naming the option for an unknown option, a missing
  required option (`name`, `max_size`) or a value of the wrong type.

      iex> Theine.Config.new!(name: :c, max_size: :infinity).write_hwm
      1024
      iex> Theine.Config.new!(name: :c, max_size: :infinity, bogus: 1)
      ** (ArgumentError) unknown option :bogus given to Theine.start_link/1
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "Theine.start_link/1 expects a keyword list, got: #{inspect(opts)}"
    end

    case Enum.find(opts, fn {key, _} -> key not in @options end) do
      nil ->
        :ok

      {key, _} ->
        raise ArgumentError, "unknown option #{inspect(key)} given to Theine.start_link/1"
    end

    name = fetch!(opts, :name)
    max_size = fetch!(opts, :max_size)

    base = %__MODULE__{
      name: name,
      max_size: max_size,
      table: name,
      maintenance: Module.concat(Theine.Maintenance, name),
      task_supervisor: Module.concat(Theine.TaskSupervisor, name),
      stripes: System.schedulers_online()
    }

    opts
    |> Keyword.drop([:name, :max_size])
    |> Enum.reduce(base, fn {key, value}, config ->
      Map.put(config, key, validate!(key, value))
    end)
    |> then(fn config ->
      %{config | name: validate!(:name, name), max_size: validate!(:max_size, max_size)}
    end)
  end

  @doc """
  Fetches the config of a running cache from `:persistent_term`. Raises
  `ArgumentError` when no cache named `cache` is running.

      Theine.Config.get(:sessions).max_size
      #=> :infinity
  """
  @spec get(cache()) :: t()
  def get(cache) when is_atom(cache), do: :persistent_term.get(cache)

  @doc """
  The `:persistent_term` key under which the config of `cache` is stored:
  the cache name itself.
  """
  @spec key(cache()) :: cache()
  def key(cache) when is_atom(cache), do: cache

  @doc """
  True when both configs were built from the same options, ignoring the
  runtime handles. `Theine.Owner` uses it to decide whether a restart may
  keep the atomics and counters already in `:persistent_term`.
  """
  @spec same_options?(t(), t()) :: boolean()
  def same_options?(%__MODULE__{} = a, %__MODULE__{} = b) do
    Map.drop(a, @runtime_fields) == Map.drop(b, @runtime_fields)
  end

  defp fetch!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError, "missing required option #{inspect(key)} for Theine.start_link/1"
    end
  end

  defp validate!(:name, name) when is_atom(name) and name not in [nil, true, false], do: name

  defp validate!(:max_size, :infinity), do: :infinity

  defp validate!(:max_size, n) when is_integer(n) and n > 0 do
    raise ArgumentError,
          "option :max_size supports only :infinity in this version (bounded caches arrive with the policy), got: #{n}"
  end

  defp validate!(:weigher, nil), do: nil
  defp validate!(:weigher, fun) when is_function(fun, 2), do: fun

  defp validate!(key, :infinity) when key in [:expire_after_write, :refresh_after_write],
    do: :infinity

  defp validate!(key, ms)
       when key in [:expire_after_write, :refresh_after_write] and is_integer(ms) and ms > 0,
       do: ms

  defp validate!(:loader, nil), do: nil
  defp validate!(:loader, fun) when is_function(fun, 1), do: fun

  defp validate!(:window_percent, n) when is_integer(n) and n in 1..80, do: n

  defp validate!(key, bool) when key in [:adaptive, :stats, :test_hooks] and is_boolean(bool),
    do: bool

  defp validate!(key, n)
       when key in [
              :stripes,
              :read_buffer_slots,
              :drain_threshold,
              :write_hwm,
              :write_batch,
              :expire_batch,
              :evict_batch,
              :maintenance_interval
            ] and is_integer(n) and n > 0,
       do: n

  defp validate!(key, value) do
    raise ArgumentError,
          "invalid value for option #{inspect(key)}: #{inspect(value)} (#{expected(key)})"
  end

  defp expected(:name), do: "expected an atom"
  defp expected(:max_size), do: "expected a positive integer or :infinity"
  defp expected(:weigher), do: "expected a function of arity 2 or nil"
  defp expected(:loader), do: "expected a function of arity 1 or nil"
  defp expected(:window_percent), do: "expected an integer in 1..80"
  defp expected(key) when key in [:adaptive, :stats, :test_hooks], do: "expected a boolean"

  defp expected(key) when key in [:expire_after_write, :refresh_after_write],
    do: "expected a positive number of milliseconds or :infinity"

  defp expected(_), do: "expected a positive integer"
end
