defmodule Theine.Maintenance do
  @moduledoc """
  The one policy process per cache (specs/04).

  Registered as `Theine.Maintenance.<cache>` so that writers can reach it
  with `send/2` and a restart needs no `:persistent_term` write: the config
  holds the name, not the pid.

  `init/1` reads the config the Owner stored, resets the `pending` counter
  and the drain flag, and creates the `Theine.Policy` tables. Write events
  (`{:put, key, id, weight, expires_at}` and `{:removed, key, id}`,
  specs/03) are applied to the policy as they arrive and decrement `pending`
  per event; nothing waits for a pass (specs/04 §The pass). A writer above
  `write_hwm` delivers its event as the call `{:event, event}` instead of a
  plain message (specs/03 §Delivery with backpressure); calls and messages
  are consumed in mailbox order and the call is replied to as its event is
  consumed.

  A pass runs on a `:drain` message from a reader (specs/03
  §`schedule_drain/1`), on the `maintenance_interval` timer, on `run/1`, and
  once `write_batch` events have been applied since the last pass. In order
  (specs/04 §The pass): flush up to `write_batch * 4` write events still
  queued in the mailbox, clear the drain flag, drain the read buffer into
  `Theine.Policy.on_access/2`, evict with `Theine.Policy.evict/1`, advance
  the sketch's reset by one chunk when one is due or running, and emit
  `[:theine, :maintenance, :pass]`. The expiry sweep (step 4) arrives with
  `Theine.Expiry` (M3.1); the `expired` measurement is 0 until then. When
  the drain found a full stripe or eviction stopped at `evict_batch`, the
  pass schedules the next one at once through
  `Theine.ReadBuffer.schedule_drain/1`.

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

  @typedoc """
  The process's view of the cache. `segments`, `read_buffer` and `sketch`
  are `nil` in an unbounded cache, which allocates neither buffer nor
  sketch (specs/08 §Acceptance). `sketch.reset` is the cursor of a reset in
  progress (specs/02 §Operations), or `nil`.
  """
  @type info :: %{
          cache: Config.cache(),
          passes: non_neg_integer(),
          last_pass_duration: non_neg_integer() | nil,
          pending: integer(),
          size: non_neg_integer(),
          weighted_size: non_neg_integer(),
          segments: Policy.weights() | nil,
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

  defstruct [
    :cache,
    :config,
    :module,
    :policy,
    passes: 0,
    last_pass_duration: nil,
    writes: 0,
    sketch_reset: nil
  ]

  @typep state :: %__MODULE__{
           cache: Config.cache(),
           config: Config.t(),
           module: module(),
           policy: Policy.t(),
           passes: non_neg_integer(),
           last_pass_duration: non_neg_integer() | nil,
           writes: non_neg_integer(),
           sketch_reset: Sketch.reset_cursor() | nil
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
  native time units, the `pending` write-event count, the entry count and
  weighted size as last seen by the policy, and for a bounded cache the
  segment weights, the read buffer's shape and lag (specs/03) and the
  sketch's size, increments since its last reset and the cursor of a reset
  in progress; those three are `nil` for `max_size: :infinity`.

      Theine.Maintenance.info(:sessions)
      #=> %{cache: :sessions, passes: 0, last_pass_duration: nil, pending: 0, size: 0,
      #=>   weighted_size: 0, segments: nil, read_buffer: nil, sketch: nil}
  """
  @spec info(Config.cache()) :: info()
  def info(cache) when is_atom(cache), do: GenServer.call(name(cache), :info)

  @doc "The policy row of `key` as the maintenance process sees it (tests)."
  @spec policy_row(Config.cache(), term()) :: {:ok, Policy.row()} | :error
  def policy_row(cache, key) when is_atom(cache), do: GenServer.call(name(cache), {:row, key})

  @impl true
  @spec init(Config.cache()) :: {:ok, state()}
  def init(cache) do
    config = Config.get(cache)
    :atomics.put(config.pending, 1, 0)
    :atomics.put(config.flags, @drain_flag, 0)
    seed_rand(cache)
    schedule_interval(config)
    module = config.policy_module

    {:ok, %__MODULE__{cache: cache, config: config, module: module, policy: module.new(config)}}
  end

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
      size: Policy.size(config.sizes),
      weighted_size: Policy.weighted_size(config.sizes),
      segments: if(bounded?, do: Policy.weights(policy), else: nil),
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
    state = apply_event(state, event)
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

  def handle_info(:drain, state), do: {:noreply, pass(state)}

  def handle_info(:interval, state) do
    schedule_interval(state.config)
    {:noreply, pass(state)}
  end

  @spec apply_event(state(), Theine.WriteEvents.event()) :: state()
  defp apply_event(state, {:put, key, id, weight, expires_at}) do
    consumed(state, state.module.on_write(state.policy, key, id, weight, expires_at))
  end

  defp apply_event(state, {:removed, key, id}) do
    consumed(state, state.module.on_remove(state.policy, key, id))
  end

  defp consumed(state, policy) do
    :atomics.sub(state.config.pending, 1, 1)
    %{state | policy: policy, writes: state.writes + 1}
  end

  # The write-count trigger: a pass once `write_batch` events have been
  # applied since the last one. Checked on arrival only, never inside a
  # pass's own flush.
  defp batch(%__MODULE__{writes: writes, config: %Config{write_batch: write_batch}} = state)
       when writes >= write_batch,
       do: pass(state)

  defp batch(state), do: state

  # One pass (specs/04 §The pass). Step 4, the expiry sweep, is M3.1 and
  # step 7, the adaptive climb, is M6.
  @spec pass(state()) :: state()
  defp pass(%__MODULE__{config: config, module: module} = state) do
    started = System.monotonic_time()

    # 1. Flush queued write events, capped, so the pass sees a policy that is
    #    not behind the mailbox and backpressure clears quickly.
    state = flush(state, config.write_batch * 4)

    # 2. Clear the drain flag before reading the buffer: a reader that
    #    crosses the threshold from here on schedules the next pass.
    :atomics.put(config.flags, @drain_flag, 0)

    # 3. Drain the read buffer into the policy.
    {policy, reads, full?} = drain(config, module, state.policy)

    # 5. Evict.
    {status, evicted, policy} = module.evict(policy)

    # 6. Age the sketch by one chunk.
    {policy, sketch_reset} = age(policy, state.sketch_reset, config)

    # A full stripe or a capped eviction wants the next pass now. The flag
    # was cleared in step 2, so this sends exactly one `:drain` unless a
    # reader already did, in which case that one serves.
    if full? or status == :more, do: ReadBuffer.schedule_drain(config)

    # 8. Record and emit.
    duration = System.monotonic_time() - started

    :telemetry.execute(
      [:theine, :maintenance, :pass],
      %{duration: duration, reads: reads, writes: state.writes, expired: 0, evicted: evicted},
      %{cache: state.cache}
    )

    %{
      state
      | policy: policy,
        sketch_reset: sketch_reset,
        passes: state.passes + 1,
        last_pass_duration: duration,
        writes: 0
    }
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
        state = apply_event(state, event)
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
