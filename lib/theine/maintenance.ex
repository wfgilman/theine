defmodule Theine.Maintenance do
  @moduledoc """
  The one policy process per cache (specs/04).

  Registered as `Theine.Maintenance.<cache>` so that writers can reach it
  with `send/2` and a restart needs no `:persistent_term` write: the config
  holds the name, not the pid.

  `init/1` reads the config the Owner stored, resets the `pending` counter,
  the drain flag and the read buffer's heads, creates the `Theine.Policy`
  tables with a cleared sketch, and then rebuilds the policy from the
  entries table (specs/04 §Restart semantics): the table is scanned in
  `:ets.select/3` chunks of 10_000 entries, one `handle_continue/2` per
  chunk, with the table fixed for the scan, and every entry is restored
  into probation with its stored weight and `expires_at`. Write events
  that arrive meanwhile wait in the mailbox and are applied once the scan
  is done; a rebuilt cache over `max_size` schedules a `:drain` so the next
  pass evicts. One `[:theine, :maintenance, :rebuild]` event reports the
  scan's `duration`, `entries` and `chunks`. A fresh start scans an empty
  table. Write events
  (`{:put, key, id, weight, expires_at}` and `{:removed, key, id}`,
  specs/03) are applied to the policy as they arrive and decrement `pending`
  per event; nothing waits for a pass (specs/04 §The pass). A `:put` is
  consumed only once the cache fits again: `Theine.Policy.on_write/5` is
  followed by `Theine.Policy.evict/1` and then by the `pending` decrement,
  so every entry the table holds beyond `max_size` is counted by `pending`
  or is an insert in flight, which is the A5 bound of specs/00 (specs/04
  §Decisions M2.11c). A writer above `write_hwm` delivers its event as the
  call `{:event, event}` instead of a plain message (specs/03 §Delivery with
  backpressure); calls and messages are consumed in mailbox order and the
  call is replied to as its event is consumed, that is after the eviction
  its entry caused.

  A pass runs on a `:drain` message from a reader (specs/03
  §`schedule_drain/1`), on the `maintenance_interval` timer, on `run/1`, and
  once `write_batch` events have been applied since the last pass. In order
  (specs/04 §The pass): flush up to `write_batch` write events still
  queued in the mailbox, clear the drain flag, drain the read buffer into
  `Theine.Policy.on_access/2`, evict with `Theine.Policy.evict/1` (a no-op
  unless a rebuild or a capped per-event eviction left the cache over
  capacity), advance the sketch's reset by one chunk when one is due or
  running, take the adaptive window's step with `Theine.Policy.climb/1`
  (a no-op with `adaptive: false`), and emit
  `[:theine, :maintenance, :pass]`, whose `evicted` is
  the number of entries evicted since the previous pass, on arrival and in
  the pass alike, as `writes` is. The expiry sweep (step 4) arrives with
  `Theine.Expiry` (M3.1); the `expired` measurement is 0 until then. When
  the drain found a full stripe or an eviction, in the pass or after an
  applied `:put`, stopped at `evict_batch` removals, the next pass is
  scheduled at once through `Theine.ReadBuffer.schedule_drain/1`.

  Drain-triggered passes are rate limited (specs/04 §The pass, §Decisions
  M2.8c): after a pass of duration `d`, a `:drain` that arrives within
  `drain_backoff * d` is deferred with a timer to the end of that gap,
  rounded up to the millisecond, and the drain flag stays set meanwhile so
  readers send nothing more; a second `:drain` in that window is dropped.
  `run/1`, the interval timer and the `write_batch` trigger are never
  deferred. Reads during the gap are dropped by the ring, which specs/03
  allows. `drain_backoff: 0` turns the limit off.

  `pause/1` and `resume/1` exist for tests (specs/04 §Responsibilities) and
  only in a cache started with `test_hooks: true`. A paused process blocks
  in a selective receive that accepts nothing but `resume/1`, so every
  write event, `:drain` and call queues in its mailbox exactly as it would
  behind a slow pass, and writers above `write_hwm` block. The same option
  unlocks `policy_module`, the module called in place of `Theine.Policy`
  (specs/10 §Required helpers `Theine.Test.Policy`).
  """

  use GenServer

  alias Theine.{Config, Policy, ReadBuffer, Sketch}

  # Index of the drain flag inside `config.flags` (specs/03).
  @drain_flag Theine.Owner.drain_flag()

  # Entries per `:ets.select/3` chunk of the restart rebuild (specs/04
  # §Restart semantics step 3), and what each chunk carries of an entry
  # `{key, value, id, weight, written_at, expires_at}`.
  @rebuild_chunk 10_000
  @rebuild_spec [{{:"$1", :_, :"$2", :"$3", :_, :"$4"}, [], [{{:"$1", :"$2", :"$3", :"$4"}}]}]

  @typedoc """
  The process's view of the cache. `segments`, `read_buffer` and `sketch`
  are `nil` in an unbounded cache, which allocates neither buffer nor
  sketch (specs/08 §Acceptance). `sketch.reset` is the cursor of a reset in
  progress (specs/02 §Operations), or `nil`. `call_writes` counts the
  write events consumed from the backpressure call path (specs/03
  §Delivery with backpressure) since the process started or was last
  `reset/1`.
  """
  @type info :: %{
          cache: Config.cache(),
          passes: non_neg_integer(),
          last_pass_duration: non_neg_integer() | nil,
          pending: integer(),
          call_writes: non_neg_integer(),
          size: non_neg_integer(),
          weighted_size: non_neg_integer(),
          segments: Policy.weights() | nil,
          climber: map() | nil,
          read_buffer:
            %{stripes: pos_integer(), slots: pos_integer(), lag: non_neg_integer()} | nil,
          sketch:
            %{
              words: pos_integer(),
              increments: non_neg_integer(),
              reset: Sketch.reset_cursor() | nil
            }
            | nil
        }

  @typedoc "The measurements of one `[:theine, :maintenance, :pass]` event."
  @type measurements :: %{
          duration: non_neg_integer(),
          reads: non_neg_integer(),
          writes: non_neg_integer(),
          expired: non_neg_integer(),
          evicted: non_neg_integer()
        }

  @typedoc """
  The measurements of the one `[:theine, :maintenance, :rebuild]` event a
  maintenance start emits: the scan's wall time in native units, the
  entries restored and the `:ets.select/3` chunks they came in.
  """
  @type rebuild_measurements :: %{
          duration: non_neg_integer(),
          entries: non_neg_integer(),
          chunks: non_neg_integer()
        }

  defstruct [
    :cache,
    :config,
    :module,
    :policy,
    passes: 0,
    last_pass_duration: nil,
    writes: 0,
    evicted: 0,
    call_writes: 0,
    sketch_reset: nil,
    drain_after: nil,
    deferred: nil
  ]

  # `writes` and `evicted` count the events applied and the entries evicted
  # since the last pass, for its telemetry. `drain_after` is the monotonic
  # time (native units) before which no drain-triggered pass may start, set
  # at the end of every pass; `deferred` is the timer of the one `:drain`
  # waiting for it, or nil. `call_writes` counts the `{:event, _}` calls
  # consumed, for `info/1`.
  @typep state :: %__MODULE__{
           cache: Config.cache(),
           config: Config.t(),
           module: module(),
           policy: Policy.t(),
           passes: non_neg_integer(),
           last_pass_duration: non_neg_integer() | nil,
           writes: non_neg_integer(),
           evicted: non_neg_integer(),
           call_writes: non_neg_integer(),
           sketch_reset: Sketch.reset_cursor() | nil,
           drain_after: integer() | nil,
           deferred: reference() | nil
         }

  @doc "Registered name of the maintenance process of `cache`."
  @spec name(Config.cache()) :: atom()
  def name(cache) when is_atom(cache), do: Module.concat(__MODULE__, cache)

  @doc false
  @spec start_link(Config.cache()) :: GenServer.on_start()
  def start_link(cache) when is_atom(cache) do
    GenServer.start_link(__MODULE__, cache, name: name(cache))
  end

  @doc """
  Forgets everything the process knows about the cache's entries. Called by
  `Theine.clear/1` after the entries table has been emptied; returns once
  the policy state is empty too.

      Theine.Maintenance.reset(:sessions)
      #=> :ok
  """
  @spec reset(Config.cache()) :: :ok
  def reset(cache) when is_atom(cache), do: GenServer.call(name(cache), :reset)

  @doc """
  Runs one full maintenance pass synchronously and returns `:ok` when it is
  complete. For tests and benches (specs/04 §Responsibilities). Write events
  the caller sent before calling are applied before the pass, in mailbox
  order.

      Theine.Maintenance.run(:sessions)
      #=> :ok
  """
  @spec run(Config.cache()) :: :ok
  def run(cache) when is_atom(cache), do: GenServer.call(name(cache), :run)

  @doc """
  Stops the process consuming anything until `resume/1`: write events,
  `:drain` messages and calls all queue in its mailbox, and writers above
  `write_hwm` block (specs/03 §Delivery with backpressure). Returns `:ok`
  once the process is paused. Tests only: raises `ArgumentError` unless the
  cache was started with `test_hooks: true`.

      Theine.Maintenance.pause(:sessions)
      #=> :ok
  """
  @spec pause(Config.cache()) :: :ok
  def pause(cache) when is_atom(cache), do: hook!(cache, :pause)

  @doc """
  Lets a process paused by `pause/1` consume its mailbox again and returns
  `:ok` once it has. A no-op on a process that is not paused. Tests only:
  raises `ArgumentError` unless the cache was started with `test_hooks:
  true`.

      Theine.Maintenance.resume(:sessions)
      #=> :ok
  """
  @spec resume(Config.cache()) :: :ok
  def resume(cache) when is_atom(cache), do: hook!(cache, :resume)

  defp hook!(cache, hook) do
    case GenServer.call(name(cache), hook, :infinity) do
      :ok ->
        :ok

      {:error, :test_hooks_disabled} ->
        raise ArgumentError,
              "Theine.Maintenance.#{hook}/1 needs the cache #{inspect(cache)} started with test_hooks: true"
    end
  end

  @doc """
  Returns the process's view of the cache: pass count, last pass duration in
  native time units, the `pending` write-event count, the number of write
  events consumed from the backpressure call path (`call_writes`, specs/03
  §Delivery with backpressure; what `mix bench maintenance` reports as the
  backpressure fraction), the entry count and weighted size as last seen by
  the policy, and for a bounded cache the segment weights, the adaptive
  window's limits and sample (`Theine.Policy.climber/1`), the read
  buffer's shape and lag (specs/03) and the sketch's size, increments since
  its last reset and the cursor of a reset in progress; those four are
  `nil` for `max_size: :infinity`.

      Theine.Maintenance.info(:sessions)
      #=> %{cache: :sessions, passes: 0, last_pass_duration: nil, pending: 0, call_writes: 0,
      #=>   size: 0, weighted_size: 0, segments: nil, climber: nil, read_buffer: nil,
      #=>   sketch: nil}
  """
  @spec info(Config.cache()) :: info()
  def info(cache) when is_atom(cache), do: GenServer.call(name(cache), :info)

  @doc "The policy row of `key` as the maintenance process sees it (tests)."
  @spec policy_row(Config.cache(), term()) :: {:ok, Policy.row()} | :error
  def policy_row(cache, key) when is_atom(cache), do: GenServer.call(name(cache), {:row, key})

  @doc "Entries per `:ets.select/3` chunk of the restart rebuild."
  @spec rebuild_chunk() :: 10_000
  def rebuild_chunk, do: @rebuild_chunk

  @impl true
  @spec init(Config.cache()) :: {:ok, state(), {:continue, :rebuild}}
  def init(cache) do
    config = Config.get(cache)

    # specs/04 §Restart semantics step 2: events the previous process never
    # consumed are gone with it, readers' triggers start over, and reads
    # recorded before now are not worth draining into a cold policy. The
    # sketch is cleared by `Policy.new/1`.
    :atomics.put(config.pending, 1, 0)
    :atomics.put(config.flags, @drain_flag, 0)
    if config.read_buffer, do: :ok = ReadBuffer.reset_heads(config)

    seed_rand(cache)
    schedule_interval(config)
    module = config.policy_module
    state = %__MODULE__{cache: cache, config: config, module: module, policy: module.new(config)}

    # Step 3 runs after init/1 returns, so the supervisor's start completes
    # and the registered name is reachable while the table is scanned.
    {:ok, state, {:continue, :rebuild}}
  end

  # The restart rebuild (specs/04 §Restart semantics steps 3 and 4), one
  # chunk per continue. The table is fixed for the scan so that a chunked
  # `:ets.select/3` traversal of a `set` neither skips nor repeats an entry
  # while writers keep inserting and deleting; the fix is released when the
  # scan ends, or by the runtime if this process dies first. No message is
  # handled between chunks: a continue chains straight into the next, so
  # the write events arriving meanwhile queue up and are applied, in
  # order, once the policy holds every entry the scan found.
  @impl true
  def handle_continue(:rebuild, %__MODULE__{config: config} = state) do
    true = :ets.safe_fixtable(config.table, true)
    started = System.monotonic_time()
    rebuild(state, :ets.select(config.table, @rebuild_spec, @rebuild_chunk), {started, 0, 0})
  end

  def handle_continue({:rebuild, continuation, progress}, state) do
    rebuild(state, :ets.select(continuation), progress)
  end

  defp rebuild(%__MODULE__{module: module} = state, {rows, continuation}, {started, n, chunks}) do
    policy =
      Enum.reduce(rows, state.policy, fn {key, id, weight, expires_at}, policy ->
        module.restore(policy, key, id, weight, expires_at)
      end)

    progress = {started, n + length(rows), chunks + 1}
    {:noreply, %{state | policy: policy}, {:continue, {:rebuild, continuation, progress}}}
  end

  defp rebuild(%__MODULE__{config: config} = state, :"$end_of_table", {started, n, chunks}) do
    true = :ets.safe_fixtable(config.table, false)
    duration = System.monotonic_time() - started

    :telemetry.execute(
      [:theine, :maintenance, :rebuild],
      %{duration: duration, entries: n, chunks: chunks},
      %{cache: state.cache}
    )

    # Step 4: over capacity, the next pass must evict. The flag was cleared
    # in init/1, so this queues one `:drain` unless a reader already did.
    if over_capacity?(config), do: ReadBuffer.schedule_drain(config)

    {:noreply, state}
  end

  defp over_capacity?(%Config{max_size: :infinity}), do: false

  defp over_capacity?(%Config{max_size: max_size, sizes: sizes}),
    do: Policy.weighted_size(sizes) > max_size

  @doc """
  The `:rand` seed of the maintenance process of `cache`, derived from the
  cache name so that admission's random guard (specs/05 §Events `evict`)
  makes the same decisions every time a trace is replayed through
  `mix bench hitrate`.

      iex> Theine.Maintenance.rand_seed(:sessions) == Theine.Maintenance.rand_seed(:sessions)
      true
  """
  @spec rand_seed(Config.cache()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def rand_seed(cache) when is_atom(cache) do
    hash = :erlang.phash2(cache)
    {hash, hash, hash}
  end

  defp seed_rand(cache) do
    _ = :rand.seed(:exsss, rand_seed(cache))
    :ok
  end

  # The periodic trigger (specs/04 §The pass): one timer at a time, re-armed
  # when it fires, so expiry runs on an idle cache too.
  defp schedule_interval(%Config{maintenance_interval: interval}) do
    _ = Process.send_after(self(), :interval, interval)
    :ok
  end

  @impl true
  def handle_call(:reset, _from, state) do
    policy = state.module.reset(state.policy)

    {:reply, :ok,
     %{
       state
       | policy: policy,
         passes: 0,
         last_pass_duration: nil,
         writes: 0,
         evicted: 0,
         call_writes: 0,
         sketch_reset: nil
     }}
  end

  def handle_call(:run, _from, state) do
    {:reply, :ok, pass(state)}
  end

  def handle_call(:info, _from, %{config: config, policy: policy} = state) do
    bounded? = is_integer(config.max_size)

    info = %{
      cache: state.cache,
      passes: state.passes,
      last_pass_duration: state.last_pass_duration,
      pending: :atomics.get(config.pending, 1),
      call_writes: state.call_writes,
      size: Policy.size(config.sizes),
      weighted_size: Policy.weighted_size(config.sizes),
      segments: if(bounded?, do: Policy.weights(policy), else: nil),
      climber: Policy.climber(policy),
      read_buffer:
        if(bounded?,
          do: %{
            stripes: config.stripes,
            slots: config.read_buffer_slots,
            lag: ReadBuffer.lag(config)
          },
          else: nil
        ),
      sketch:
        if(bounded?,
          do: %{
            words: Sketch.words(config.max_size),
            increments: policy.sketch_size,
            reset: state.sketch_reset
          },
          else: nil
        )
    }

    {:reply, info, state}
  end

  def handle_call({:row, key}, _from, state) do
    {:reply, Policy.lookup(state.policy, key), state}
  end

  # The backpressure path (specs/03): the writer waits for its event to be
  # consumed, so the reply is the consumption, and it goes out before a pass
  # the event may trigger.
  def handle_call({:event, event}, from, state) do
    state = apply_call_event(state, event)
    GenServer.reply(from, :ok)
    {:noreply, batch(state)}
  end

  def handle_call(:pause, from, %{config: %Config{test_hooks: true}} = state) do
    GenServer.reply(from, :ok)

    # Paused means consuming nothing: block here, where only `resume/1` can
    # get through, so write events, calls and :drain pile up in the mailbox
    # exactly as they would behind a slow pass. The call tuple shape is the
    # one GenServer documents; the `from` goes straight back to reply/2.
    receive do
      {:"$gen_call", resume_from, :resume} -> GenServer.reply(resume_from, :ok)
    end

    {:noreply, state}
  end

  def handle_call(:resume, _from, %{config: %Config{test_hooks: true}} = state) do
    {:reply, :ok, state}
  end

  def handle_call(hook, _from, state) when hook in [:pause, :resume] do
    {:reply, {:error, :test_hooks_disabled}, state}
  end

  # Write events are applied on arrival (specs/04 §The pass, first paragraph).
  @impl true
  def handle_info({:put, _, _, _, _} = event, state),
    do: {:noreply, state |> apply_event(event) |> batch()}

  def handle_info({:removed, _, _} = event, state),
    do: {:noreply, state |> apply_event(event) |> batch()}

  # A reader's or a follow-up's `:drain` (specs/03 §`schedule_drain/1`).
  # While one is deferred, another is dropped: the flag has stayed set, so
  # this can only be a message that was already in flight when the last pass
  # cleared it, and the deferred pass serves both.
  def handle_info(:drain, %__MODULE__{deferred: ref} = state) when is_reference(ref),
    do: {:noreply, state}

  def handle_info(:drain, %__MODULE__{drain_after: nil} = state), do: {:noreply, pass(state)}

  def handle_info(:drain, %__MODULE__{drain_after: drain_after} = state) do
    remaining = drain_after - System.monotonic_time()

    if remaining > 0 do
      ref = Process.send_after(self(), :deferred_drain, ceil_ms(remaining))
      {:noreply, %{state | deferred: ref}}
    else
      {:noreply, pass(state)}
    end
  end

  def handle_info(:deferred_drain, state), do: {:noreply, pass(%{state | deferred: nil})}

  def handle_info(:interval, state) do
    schedule_interval(state.config)
    {:noreply, pass(state)}
  end

  # A `:put` is consumed once the cache fits again (specs/03 §Delivery with
  # backpressure, specs/04 §The pass): the policy learns the entry and
  # evicts what it displaced, and only then is `pending` decremented and a
  # call-path writer answered. Every entry beyond `max_size` is therefore
  # counted by `pending` or in flight between its insert and its count,
  # which is the A5 bound. An entry heavier than `evict_batch` removals
  # leaves the cache over capacity with `:more`; the pass this schedules
  # finishes the eviction, as after a capped step 5.
  @spec apply_event(state(), Theine.WriteEvents.event()) :: state()
  defp apply_event(%__MODULE__{module: module, config: config} = state, {:put, key, id, w, exp}) do
    {status, evicted, policy} = module.evict(module.on_write(state.policy, key, id, w, exp))
    if status == :more, do: ReadBuffer.schedule_drain(config)
    consumed(%{state | evicted: state.evicted + evicted}, policy)
  end

  defp apply_event(state, {:removed, key, id}) do
    consumed(state, state.module.on_remove(state.policy, key, id))
  end

  defp consumed(state, policy) do
    :atomics.sub(state.config.pending, 1, 1)
    %{state | policy: policy, writes: state.writes + 1}
  end

  # An event that arrived as a backpressure call (specs/03 §Delivery with
  # backpressure): applied like any other, and counted for `info/1`.
  defp apply_call_event(state, event) do
    state = apply_event(state, event)
    %{state | call_writes: state.call_writes + 1}
  end

  # The write-count trigger: a pass once `write_batch` events have been
  # applied since the last one. Checked on arrival only, never inside a
  # pass's own flush.
  defp batch(%__MODULE__{writes: writes, config: %Config{write_batch: write_batch}} = state)
       when writes >= write_batch,
       do: pass(state)

  defp batch(state), do: state

  # One pass (specs/04 §The pass). Step 4, the expiry sweep, is M3.1.
  @spec pass(state()) :: state()
  defp pass(%__MODULE__{config: config, module: module} = state) do
    started = System.monotonic_time()

    # 1. Flush queued write events, capped at `write_batch`, so the pass sees
    #    a policy that is not far behind the mailbox. Events are applied on
    #    arrival anyway, so the cap bounds the pass's length, not the
    #    process's throughput (specs/04 §Decisions M2.11d).
    state = flush(state, config.write_batch)

    # 2. Clear the drain flag before reading the buffer: a reader that
    #    crosses the threshold from here on schedules the next pass. Not
    #    while a deferred `:drain` is pending: that one is the next pass, and
    #    the set flag is what keeps readers from sending another.
    if is_nil(state.deferred), do: :atomics.put(config.flags, @drain_flag, 0)

    # 3. Drain the read buffer into the policy.
    {policy, reads, full?} = drain(config, module, state.policy)

    # 5. Evict. Every applied `:put` already evicted what it displaced, so
    #    this finds work only after a restart rebuild or a capped per-event
    #    eviction, and otherwise costs two comparisons.
    {status, evicted, policy} = module.evict(policy)

    # 6. Age the sketch by one chunk.
    {policy, sketch_reset} = age(policy, state.sketch_reset, config)

    # 7. The adaptive step: a no-op unless the cache is bounded and
    #    `adaptive` (specs/05 §Adaptive window).
    policy = module.climb(policy)

    # A full stripe or a capped eviction wants the next pass now. The flag
    # was cleared in step 2, so this sends exactly one `:drain` unless a
    # reader already did, in which case that one serves.
    if full? or status == :more, do: ReadBuffer.schedule_drain(config)

    # 8. Record and emit. `writes` and `evicted` are counts since the
    #    previous pass, on arrival and in this pass alike.
    finished = System.monotonic_time()
    duration = finished - started

    :telemetry.execute(
      [:theine, :maintenance, :pass],
      %{
        duration: duration,
        reads: reads,
        writes: state.writes,
        expired: 0,
        evicted: state.evicted + evicted
      },
      %{cache: state.cache}
    )

    %{
      state
      | policy: policy,
        sketch_reset: sketch_reset,
        passes: state.passes + 1,
        last_pass_duration: duration,
        writes: 0,
        evicted: 0,
        drain_after: finished + config.drain_backoff * duration
    }
  end

  # Native units to whole milliseconds, rounded up, so a deferred pass never
  # starts before `drain_after`.
  defp ceil_ms(native) when native > 0 do
    per_ms = max(System.convert_time_unit(1, :millisecond, :native), 1)
    div(native + per_ms - 1, per_ms)
  end

  # Step 1: write events and backpressure calls still in the mailbox, in
  # their order, up to `limit` of them. Other messages stay where they are.
  defp flush(state, 0), do: state

  defp flush(state, limit) do
    receive do
      {:put, _, _, _, _} = event ->
        flush(apply_event(state, event), limit - 1)

      {:removed, _, _} = event ->
        flush(apply_event(state, event), limit - 1)

      {:"$gen_call", from, {:event, event}} ->
        state = apply_call_event(state, event)
        GenServer.reply(from, :ok)
        flush(state, limit - 1)
    after
      0 -> state
    end
  end

  # Step 3: nothing to drain without a bound (no read buffer is allocated).
  defp drain(%Config{read_buffer: nil}, _module, policy), do: {policy, 0, false}

  defp drain(config, module, policy) do
    ReadBuffer.drain(config, policy, fn id, policy -> module.on_access(policy, id) end)
  end

  # Step 6 (specs/02 §Operations `reset/1`): a reset starts once the
  # increments since the last one reach `sample_size` and advances by one
  # chunk per pass; on completion the increment count follows the odd-count
  # rule. The count lives in the policy struct (specs/05 §Decisions M2.4).
  defp age(%Policy{sketch: nil} = policy, nil, _config), do: {policy, nil}

  defp age(%Policy{sketch_size: size} = policy, nil, %Config{max_size: max_size}) do
    if size >= Sketch.sample_size(max_size),
      do: advance(policy, Sketch.reset_start()),
      else: {policy, nil}
  end

  defp age(policy, cursor, _config), do: advance(policy, cursor)

  defp advance(%Policy{sketch: sketch, sketch_size: size} = policy, cursor) do
    case Sketch.reset(sketch, cursor) do
      {:more, cursor} -> {policy, cursor}
      {:done, odd} -> {%{policy | sketch_size: Sketch.size_after_reset(size, odd)}, nil}
    end
  end
end
