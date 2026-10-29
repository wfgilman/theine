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
  consumed. The pass itself only records its duration so far: the
  read-buffer drain, expiry sweep and eviction arrive with the tasks that
  own them.

  `pause/1` and `resume/1` exist for tests (specs/04 §Responsibilities) and
  only in a cache started with `test_hooks: true`. A paused process blocks
  in a selective receive that accepts nothing but `resume/1`, so every
  write event, `:drain` and call queues in its mailbox exactly as it would
  behind a slow pass, and writers above `write_hwm` block.
  """

  use GenServer

  alias Theine.{Config, Policy, ReadBuffer, Sketch}

  @typedoc """
  The process's view of the cache. `segments`, `read_buffer` and `sketch`
  are `nil` in an unbounded cache, which allocates neither buffer nor
  sketch (specs/08 §Acceptance).
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
          sketch: %{words: pos_integer(), increments: non_neg_integer()} | nil
        }

  defstruct [:cache, :config, :policy, passes: 0, last_pass_duration: nil, writes: 0]

  @typep state :: %__MODULE__{
           cache: Config.cache(),
           config: Config.t(),
           policy: Policy.t(),
           passes: non_neg_integer(),
           last_pass_duration: non_neg_integer() | nil,
           writes: non_neg_integer()
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
  sketch's size and increments since its last reset; those three are `nil`
  for `max_size: :infinity`.

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
    :atomics.put(config.flags, Theine.Owner.drain_flag(), 0)
    {:ok, %__MODULE__{cache: cache, config: config, policy: Policy.new(config)}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    policy = Policy.reset(state.policy)
    {:reply, :ok, %{state | policy: policy, passes: 0, last_pass_duration: nil, writes: 0}}
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
          do: %{words: Sketch.words(config.max_size), increments: policy.sketch_size},
          else: nil
        )
    }

    {:reply, info, state}
  end

  def handle_call({:row, key}, _from, state) do
    {:reply, Policy.lookup(state.policy, key), state}
  end

  # The backpressure path (specs/03): the writer waits for its event to be
  # consumed, so the reply is the consumption.
  def handle_call({:event, event}, _from, state) do
    {:reply, :ok, apply_event(state, event)}
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
  def handle_info({:put, _, _, _, _} = event, state), do: {:noreply, apply_event(state, event)}
  def handle_info({:removed, _, _} = event, state), do: {:noreply, apply_event(state, event)}

  @spec apply_event(state(), Theine.WriteEvents.event()) :: state()
  defp apply_event(state, {:put, key, id, weight, expires_at}) do
    consumed(state, Policy.on_write(state.policy, key, id, weight, expires_at))
  end

  defp apply_event(state, {:removed, key, id}) do
    consumed(state, Policy.on_remove(state.policy, key, id))
  end

  defp consumed(state, policy) do
    :atomics.sub(state.config.pending, 1, 1)
    %{state | policy: policy, writes: state.writes + 1}
  end

  # One pass (specs/04 §The pass). Nothing to drain or evict yet: the
  # policy, expiry and read-buffer steps are added by the tasks that own them.
  @spec pass(state()) :: state()
  defp pass(state) do
    started = System.monotonic_time()

    %{
      state
      | passes: state.passes + 1,
        last_pass_duration: System.monotonic_time() - started,
        writes: 0
    }
  end
end
