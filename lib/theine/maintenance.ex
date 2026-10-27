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
  per event; nothing waits for a pass (specs/04 §The pass). The pass itself
  only records its duration so far: the read-buffer drain, expiry sweep and
  eviction arrive with the tasks that own them.
  """

  use GenServer

  alias Theine.{Config, Policy}

  @type info :: %{
          cache: Config.cache(),
          passes: non_neg_integer(),
          last_pass_duration: non_neg_integer() | nil,
          pending: integer(),
          size: non_neg_integer(),
          weighted_size: non_neg_integer()
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
  Returns the process's view of the cache: pass count, last pass duration in
  native time units, the `pending` write-event count, and the entry count
  and weighted size as last seen by the policy.

      Theine.Maintenance.info(:sessions)
      #=> %{cache: :sessions, passes: 0, last_pass_duration: nil, pending: 0, size: 0, weighted_size: 0}
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

  def handle_call(:info, _from, state) do
    info = %{
      cache: state.cache,
      passes: state.passes,
      last_pass_duration: state.last_pass_duration,
      pending: :atomics.get(state.config.pending, 1),
      size: Policy.size(state.config.sizes),
      weighted_size: Policy.weighted_size(state.config.sizes)
    }

    {:reply, info, state}
  end

  def handle_call({:row, key}, _from, state) do
    {:reply, Policy.lookup(state.policy, key), state}
  end

  # Write events are applied on arrival (specs/04 §The pass, first paragraph).
  @impl true
  def handle_info({:put, key, id, weight, expires_at}, state) do
    {:noreply, consumed(state, Policy.on_write(state.policy, key, id, weight, expires_at))}
  end

  def handle_info({:removed, key, id}, state) do
    {:noreply, consumed(state, Policy.on_remove(state.policy, key, id))}
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
