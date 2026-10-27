defmodule Theine do
  @moduledoc """
  A bounded in-memory cache for the BEAM, modelled on Java's Caffeine.

  Entries live in ETS; access buffers and the frequency sketch live in
  `:atomics`; one maintenance process per cache owns the W-TinyLFU policy.
  The public API is specified in `specs/08-api-and-lifecycle.md`.

  ## Starting a cache

  Put a cache in your supervision tree:

      children = [
        {Theine, name: :sessions, max_size: :infinity}
      ]

  Each start writes the cache's resolved configuration to `:persistent_term`
  under the cache name once, and stopping the cache erases it. A
  `:persistent_term` write triggers a global garbage collection, so a system
  that starts and stops many short-lived caches (a test suite, for example)
  pays that cost per cache. The key is the bare cache name, so a cache
  cannot share its name with a `:persistent_term` key used elsewhere;
  `start_link/1` fails if that key already holds a foreign term.

  ## Options

  | option | type | default |
  |---|---|---|
  | `name` | atom | required |
  | `max_size` | `:infinity` (bounded caches arrive with the policy) | required |
  | `weigher` | `(key, value -> pos_integer)` or `nil` | `nil` (weight 1) |
  | `expire_after_write` | ms or `:infinity` | `:infinity` |
  | `refresh_after_write` | ms or `:infinity` | `:infinity` |
  | `loader` | `(key -> {:commit, v} \\| {:commit, v, ttl: ms} \\| {:ignore, v})` or `nil` | `nil` |
  | `window_percent` | 1..80 | 1 |
  | `adaptive` | boolean | `false` |
  | `stripes` | pos_integer | `System.schedulers_online()` |
  | `read_buffer_slots` | pos_integer | 64 |
  | `drain_threshold` | pos_integer | 32 |
  | `write_hwm` | pos_integer | 1024 |
  | `write_batch` | pos_integer | 256 |
  | `expire_batch` | pos_integer | 1024 |
  | `evict_batch` | pos_integer | 1024 |
  | `maintenance_interval` | ms | 1000 |
  | `stats` | boolean | `true` |

  An unknown option, a missing `name` or `max_size`, or a value of the wrong
  type raises `ArgumentError` naming the option.
  """

  alias Theine.{Config, Entry, Policy}

  @type cache :: Config.cache()
  @type key :: Entry.key()
  @type value :: Entry.value()

  # :counters fields (specs/08 §Stats order); Theine.Stats names them in
  # M1.6. Kept in step with Theine.Entry.
  @hits 1
  @misses 2

  @doc """
  Starts a cache and its supervision tree, linked to the caller.

  Returns `{:ok, pid}` of the cache's supervisor, or
  `{:error, {:already_started, pid}}` when a cache with that name is running.
  See the module documentation for the options.

      iex> {:ok, pid} = Theine.start_link(name: :start_link_doc, max_size: :infinity)
      iex> Theine.start_link(name: :start_link_doc, max_size: :infinity)
      {:error, {:already_started, pid}}
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    opts |> Config.new!() |> Theine.Supervisor.start_link()
  end

  @doc """
  Returns a child specification for a cache, so `{Theine, opts}` can be
  listed under a supervisor. The child id is `{Theine, name}`.

      iex> Theine.child_spec(name: :spec_doc, max_size: :infinity).id
      {Theine, :spec_doc}
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %Config{name: name} = Config.new!(opts)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Returns `{:ok, value}` when `key` is present and not expired, else
  `:error`. Mirrors `Map.fetch/2`.

  A hit costs one ETS lookup, one `:persistent_term` read, one counter
  increment, and a clock read only when the entry carries an expiry; it
  never writes to the table. An expired entry is deleted by the reader and
  reported as a miss (specs/01 §Read path).

      iex> {:ok, _} = Theine.start_link(name: :get_doc, max_size: :infinity)
      iex> Theine.put(:get_doc, :a, 1)
      :ok
      iex> Theine.get(:get_doc, :a)
      {:ok, 1}
      iex> Theine.get(:get_doc, :missing)
      :error
  """
  @spec get(cache(), key()) :: {:ok, value()} | :error
  def get(cache, key) do
    # The hot path (specs/01 §Read path, AGENTS.md). The entries table is
    # named after the cache, so the lookup needs no config; the config is
    # read only for the counters. Written out in full here rather than
    # delegated: every call and map access costs against the A1 budget.
    case :ets.lookup(cache, key) do
      [{_, value, _, _, _, expires_at} = entry] ->
        # The clock is the BIF behind System.monotonic_time/1 (specs/01
        # §Decisions); it is read only for entries that can expire.
        if is_integer(expires_at) and :erlang.monotonic_time(:millisecond) >= expires_at do
          Entry.expired(:persistent_term.get(cache), entry)
        else
          %{counters: counters} = :persistent_term.get(cache)
          :counters.add(counters, @hits, 1)
          {:ok, value}
        end

      [] ->
        %{counters: counters} = :persistent_term.get(cache)
        :counters.add(counters, @misses, 1)
        :error
    end
  end

  @doc """
  Returns the value of `key`, or `default` when it is absent or expired.
  Mirrors `Map.get/3`.

      iex> {:ok, _} = Theine.start_link(name: :get3_doc, max_size: :infinity)
      iex> Theine.put(:get3_doc, :a, 1)
      :ok
      iex> Theine.get(:get3_doc, :a, 0)
      1
      iex> Theine.get(:get3_doc, :missing, 0)
      0
  """
  @spec get(cache(), key(), value()) :: value()
  def get(cache, key, default) do
    case get(cache, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  Stores `value` under `key`, replacing any existing entry, and returns
  `:ok`. The maintenance process learns of the write asynchronously.

  Options:

  - `ttl:` milliseconds or `:infinity`, the time after which the entry
    expires; defaults to the cache's `expire_after_write`.
  - `weight:` a positive integer, the entry's weight toward `max_size`;
    defaults to 1.

      iex> {:ok, _} = Theine.start_link(name: :put_doc, max_size: :infinity)
      iex> Theine.put(:put_doc, :a, 1)
      :ok
      iex> Theine.put(:put_doc, :a, 2, ttl: :timer.minutes(5), weight: 3)
      :ok
      iex> Theine.get(:put_doc, :a)
      {:ok, 2}
  """
  @spec put(cache(), key(), value(), keyword()) :: :ok
  def put(cache, key, value, opts \\ []) when is_list(opts) do
    Entry.put(:persistent_term.get(cache), key, value, opts)
  end

  @doc """
  Number of entries as last seen by the maintenance process: writes it has
  not yet consumed are not counted. Never reads `:ets.info/2`.

      iex> {:ok, _} = Theine.start_link(name: :size_doc, max_size: :infinity)
      iex> Theine.put(:size_doc, :a, 1)
      iex> Theine.put(:size_doc, :a, 2)
      iex> Theine.run_maintenance(:size_doc)
      iex> Theine.size(:size_doc)
      1
  """
  @spec size(cache()) :: non_neg_integer()
  def size(cache) do
    Policy.size(:persistent_term.get(cache).sizes)
  end

  @doc """
  Sum of the entry weights as last seen by the maintenance process.

      iex> {:ok, _} = Theine.start_link(name: :weighted_doc, max_size: :infinity)
      iex> Theine.put(:weighted_doc, :a, 1, weight: 3)
      iex> Theine.put(:weighted_doc, :b, 2)
      iex> Theine.run_maintenance(:weighted_doc)
      iex> Theine.weighted_size(:weighted_doc)
      4
  """
  @spec weighted_size(cache()) :: non_neg_integer()
  def weighted_size(cache) do
    Policy.weighted_size(:persistent_term.get(cache).sizes)
  end

  @doc """
  Runs one full maintenance pass and returns `:ok` when it is complete. For
  tests and benchmarks. Write events the caller sent before calling are
  applied before the pass.

      iex> {:ok, _} = Theine.start_link(name: :run_doc, max_size: :infinity)
      iex> Theine.run_maintenance(:run_doc)
      :ok
  """
  @spec run_maintenance(cache()) :: :ok
  def run_maintenance(cache), do: Theine.Maintenance.run(cache)
end
