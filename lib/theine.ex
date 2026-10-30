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
  | `max_size` | pos_integer (total weight) or `:infinity` | required |
  | `weigher` | `(key, value -> pos_integer)` or `nil` | `nil` (weight 1) |
  | `expire_after_write` | ms or `:infinity` | `:infinity` |
  | `refresh_after_write` | ms or `:infinity` | `:infinity` |
  | `loader` | `(key -> {:commit, v} \\| {:commit, v, ttl: ms} \\| {:ignore, v})` or `nil` | `nil` |
  | `window_percent` | 1..80 | 1 |
  | `adaptive` | boolean | `true` |
  | `stripes` | power of two | `System.schedulers_online()` rounded up to one |
  | `read_buffer_slots` | power of two | 64 |
  | `drain_threshold` | power of two | 32 |
  | `write_hwm` | pos_integer | 1024 |
  | `write_batch` | pos_integer | 256 |
  | `expire_batch` | pos_integer | 1024 |
  | `evict_batch` | pos_integer | 1024 |
  | `maintenance_interval` | ms | 1000 |
  | `stats` | boolean | `true` |
  | `test_hooks` | boolean | `false` |
  | `policy_module` | module | `Theine.Policy` (tests only, needs `test_hooks`) |

  An unknown option, a missing `name` or `max_size`, or a value of the wrong
  type raises `ArgumentError` naming the option.

  `max_size: :infinity` disables the policy entirely: no frequency sketch,
  no read buffer, no eviction; expiration and loading still work. A finite
  `max_size` bounds the total entry weight and allocates both: every hit
  then records the entry's id in the read buffer, and the maintenance
  process evicts by W-TinyLFU (specs/05) once the weight exceeds the bound.
  The admission window starts at `window_percent` of `max_size`; with
  `adaptive: true` the maintenance process then moves it with Caffeine's
  hill climber, growing it while recency pays and shrinking it while
  frequency does, and `adaptive: false` keeps it fixed.

  The `weigher` is called on every write without a `weight:` option and
  must return a positive integer; an entry heavier than `max_size` is never
  stored (see `put/4`).

  `test_hooks: true` enables `Theine.Maintenance.pause/1` and `resume/1`,
  which stop and restart the maintenance process's consumption of write
  events so tests can observe backpressure and lazy expiry, and unlocks
  `policy_module`, the module the maintenance process calls in place of
  `Theine.Policy` (the test suite injects an instrumented one that records
  the call order of a pass). Never set it in production: a paused cache
  blocks writers once `write_hwm` events queue.
  """

  alias Theine.{Config, Entry, Policy, ReadBuffer, Stats}

  require Theine.Clock

  @type cache :: Config.cache()
  @type key :: Entry.key()
  @type value :: Entry.value()

  # :counters indices, resolved at compile time so the hot path makes no
  # call into Theine.Stats.
  @hits Stats.hits()
  @misses Stats.misses()

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

  A hit costs one ETS lookup, one `:persistent_term` read, a clock read
  only when the entry carries an expiry, and then either one counter
  increment (unbounded cache; none with `stats: false`) or, in a bounded
  cache, one scheduler-id read and two `:atomics` ops that record the
  read in the read buffer (specs/03), plus one more op and a message to
  the maintenance process once per `drain_threshold` reads. It never
  writes to the table. An expired entry is deleted by the reader and
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
    # read only after a hit or a miss is known. Written out in full here
    # rather than delegated: every call and map access costs against the
    # A1 budget.
    case :ets.lookup(cache, key) do
      [{_, value, id, _, _, expires_at} = entry] ->
        # The clock expands to the BIF behind System.monotonic_time/1
        # (specs/01 §Decisions; the test build injects Theine.Test.Clock,
        # specs/06 §Clock); it is read only for entries that can expire.
        if is_integer(expires_at) and Theine.Clock.now(cache) >= expires_at do
          Entry.expired(:persistent_term.get(cache), entry)
        else
          # `hit` is the one config key the hit path reads (specs/08
          # §Decisions M2.8): the read-buffer tuple when bounded, else the
          # request counters, or nil with `stats: false`. The bounded
          # branch is a local function so that this one stays as small as
          # the unbounded-only version measured in M2.3 (a bigger body
          # cost the unbounded hit about 10 ns in the bench).
          case :persistent_term.get(cache) do
            %{hit: {buffer, stripe_mask, width, slot_mask, trigger_mask}} = config ->
              record(config, buffer, stripe_mask, width, slot_mask, trigger_mask, id)

            %{hit: nil} ->
              :ok

            %{hit: counters} ->
              :counters.add(counters, @hits, 1)
          end

          {:ok, value}
        end

      [] ->
        case :persistent_term.get(cache) do
          %{request_counters: nil} -> :ok
          %{request_counters: counters} -> :counters.add(counters, @misses, 1)
        end

        :error
    end
  end

  # The bounded hit: `Theine.ReadBuffer.record/2` with the sizes taken from
  # the `hit` tuple as masks (specs/01 §Read path step 5, specs/03
  # §`record/2`), local so that no call leaves the module. Claim a sequence
  # in the scheduler's stripe, write the id into its slot (overwriting an
  # undrained read rather than reading the head to refuse it; specs/03
  # §Decisions M2.8b), and ask for a pass on every `drain_threshold`-th
  # sequence. Masks, not `rem`: the three divisions cost about 34 ns of a
  # 65 ns budget in a compiled loop. The sum of the tails is the hit
  # count, so no counter op (specs/03 §Hits from the tails). Not inlined:
  # the point is to keep `get/2` small.
  defp record(config, buffer, stripe_mask, width, slot_mask, trigger_mask, id) do
    base = Bitwise.band(:erlang.system_info(:scheduler_id) - 1, stripe_mask) * width + 1
    n = :atomics.add_get(buffer, base, 1)
    :atomics.put(buffer, base + 2 + Bitwise.band(n - 1, slot_mask), id)
    if Bitwise.band(n, trigger_mask) == 0, do: ReadBuffer.schedule_drain(config)
    :ok
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
    defaults to the cache's `weigher` applied to the key and value, or 1
    without one.

  An entry whose weight exceeds `max_size` is not stored: the call returns
  `:ok` and the cache is unchanged, as Caffeine does with oversized entries.

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
  Stores `value` under `key` only when `key` is absent. Returns `:ok` when
  stored, `{:error, :exists}` otherwise; an existing entry is left as it is
  and the maintenance process hears nothing. An expired entry counts as
  absent and is replaced. Takes the same options as `put/4`, with the same
  treatment of oversized entries.

      iex> {:ok, _} = Theine.start_link(name: :put_new_doc, max_size: :infinity)
      iex> Theine.put_new(:put_new_doc, :a, 1)
      :ok
      iex> Theine.put_new(:put_new_doc, :a, 2)
      {:error, :exists}
      iex> Theine.get(:put_new_doc, :a)
      {:ok, 1}
  """
  @spec put_new(cache(), key(), value(), keyword()) :: :ok | {:error, :exists}
  def put_new(cache, key, value, opts \\ []) when is_list(opts) do
    Entry.put_new(:persistent_term.get(cache), key, value, opts)
  end

  @doc """
  Removes `key` and returns `:ok`, whether or not it was present. The
  current version is looked up first and deleted by exact object, so a
  concurrent `put/4` of the same key is never lost (specs/01 §Write path).

      iex> {:ok, _} = Theine.start_link(name: :delete_doc, max_size: :infinity)
      iex> Theine.put(:delete_doc, :a, 1)
      :ok
      iex> Theine.delete(:delete_doc, :a)
      :ok
      iex> Theine.delete(:delete_doc, :a)
      :ok
      iex> Theine.get(:delete_doc, :a)
      :error
  """
  @spec delete(cache(), key()) :: :ok
  def delete(cache, key) do
    Entry.delete(:persistent_term.get(cache), key)
  end

  @doc """
  Removes every entry and returns `:ok` once the maintenance process has
  forgotten them too, so `size/1` reads 0 afterwards. The cache's
  configuration and statistics are untouched.

      iex> {:ok, _} = Theine.start_link(name: :clear_doc, max_size: :infinity)
      iex> Theine.put(:clear_doc, :a, 1)
      :ok
      iex> Theine.clear(:clear_doc)
      :ok
      iex> {Theine.get(:clear_doc, :a), Theine.size(:clear_doc)}
      {:error, 0}
  """
  @spec clear(cache()) :: :ok
  def clear(cache) do
    %{table: table} = :persistent_term.get(cache)
    true = :ets.delete_all_objects(table)
    Theine.Maintenance.reset(cache)
  end

  @doc """
  Sets a new expiry for an existing `key`, `ms` milliseconds from now or
  `:infinity`, without changing its value. Returns `true`, or `false` when
  `key` is absent or already expired. Changing an entry's expiry is not an
  access: the eviction policy does not count it as a use (specs/05).

      iex> {:ok, _} = Theine.start_link(name: :expire_doc, max_size: :infinity)
      iex> Theine.put(:expire_doc, :a, 1)
      :ok
      iex> Theine.expire(:expire_doc, :a, :timer.minutes(5))
      true
      iex> {:ok, ms} = Theine.ttl(:expire_doc, :a)
      iex> ms > 0 and ms <= :timer.minutes(5)
      true
      iex> Theine.expire(:expire_doc, :missing, 1_000)
      false
  """
  @spec expire(cache(), key(), pos_integer() | :infinity) :: boolean()
  def expire(cache, key, ms) do
    Entry.expire(:persistent_term.get(cache), key, ms)
  end

  @doc """
  Removes the expiry of an existing `key`, so it never expires. Returns
  `true`, or `false` when `key` is absent or already expired. Same as
  `expire(cache, key, :infinity)`.

      iex> {:ok, _} = Theine.start_link(name: :persist_doc, max_size: :infinity)
      iex> Theine.put(:persist_doc, :a, 1, ttl: 1_000)
      :ok
      iex> Theine.persist(:persist_doc, :a)
      true
      iex> Theine.ttl(:persist_doc, :a)
      {:ok, :infinity}
  """
  @spec persist(cache(), key()) :: boolean()
  def persist(cache, key), do: expire(cache, key, :infinity)

  @doc """
  Returns `{:ok, ms}` with the milliseconds left before `key` expires,
  `{:ok, :infinity}` when it never does, or `:error` when it is absent or
  already expired. Not a read in the statistics: it counts neither a hit
  nor a miss.

      iex> {:ok, _} = Theine.start_link(name: :ttl_doc, max_size: :infinity)
      iex> Theine.put(:ttl_doc, :a, 1)
      :ok
      iex> Theine.ttl(:ttl_doc, :a)
      {:ok, :infinity}
      iex> Theine.ttl(:ttl_doc, :missing)
      :error
  """
  @spec ttl(cache(), key()) :: {:ok, pos_integer() | :infinity} | :error
  def ttl(cache, key) do
    Entry.ttl(:persistent_term.get(cache), key)
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
  Returns the cache's statistics as a `%Theine.Stats{}`: `hits`, `misses`,
  `loads`, `load_failures`, `evictions`, `expirations`, `refreshes` and the
  computed `hit_rate` (`0.0` with no requests).

  In a bounded cache `hits` is the number of reads recorded in the read
  buffer, which every hit does, so it survives a maintenance restart and
  counts reads the buffer dropped. With `stats: false` the request
  counters stay at zero: `get/2` counts neither hits nor misses, so
  `hit_rate` is `0.0`. The event counters are maintained either way (see
  `Theine.Stats`). `clear/1` leaves the statistics untouched.

      iex> {:ok, _} = Theine.start_link(name: :stats_doc, max_size: :infinity)
      iex> Theine.put(:stats_doc, :a, 1)
      iex> Theine.get(:stats_doc, :a)
      iex> Theine.get(:stats_doc, :a)
      iex> Theine.get(:stats_doc, :missing)
      iex> %Theine.Stats{hits: 2, misses: 1, hit_rate: rate} = Theine.stats(:stats_doc)
      iex> Float.round(rate, 3)
      0.667
  """
  @spec stats(cache()) :: Stats.t()
  def stats(cache) do
    Stats.read(:persistent_term.get(cache))
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
