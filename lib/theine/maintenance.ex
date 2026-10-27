defmodule Theine.Maintenance do
  @moduledoc """
  The one policy process per cache (specs/04).

  Registered as `Theine.Maintenance.<cache>` so that writers can reach it
  with `send/2` and a restart needs no `:persistent_term` write: the config
  holds the name, not the pid.

  This is the process skeleton: `init/1` reads the config the Owner stored,
  resets the `pending` counter and the drain flag, and serves `reset/1`,
  `run/1` and `info/1`. Write events, the pass and the policy tables arrive
  with the store, policy and expiry tasks and extend this process in place.
  """

  use GenServer

  alias Theine.Config

  @type info :: %{
          cache: Config.cache(),
          passes: non_neg_integer(),
          last_pass_duration: non_neg_integer() | nil,
          pending: integer()
        }

  defstruct [:cache, :config, passes: 0, last_pass_duration: nil]

  @typep state :: %__MODULE__{
           cache: Config.cache(),
           config: Config.t(),
           passes: non_neg_integer(),
           last_pass_duration: non_neg_integer() | nil
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
  complete. For tests and benches (specs/04 §Responsibilities).

      Theine.Maintenance.run(:sessions)
      #=> :ok
  """
  @spec run(Config.cache()) :: :ok
  def run(cache) when is_atom(cache), do: GenServer.call(name(cache), :run)

  @doc """
  Returns the process's view of the cache: pass count, last pass duration in
  native time units, and the `pending` write-event count.

      Theine.Maintenance.info(:sessions)
      #=> %{cache: :sessions, passes: 0, last_pass_duration: nil, pending: 0}
  """
  @spec info(Config.cache()) :: info()
  def info(cache) when is_atom(cache), do: GenServer.call(name(cache), :info)

  @impl true
  @spec init(Config.cache()) :: {:ok, state()}
  def init(cache) do
    config = Config.get(cache)
    :atomics.put(config.pending, 1, 0)
    :atomics.put(config.flags, Theine.Owner.drain_flag(), 0)
    {:ok, %__MODULE__{cache: cache, config: config}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | passes: 0, last_pass_duration: nil}}
  end

  def handle_call(:run, _from, state) do
    {:reply, :ok, pass(state)}
  end

  def handle_call(:info, _from, state) do
    info = %{
      cache: state.cache,
      passes: state.passes,
      last_pass_duration: state.last_pass_duration,
      pending: :atomics.get(state.config.pending, 1)
    }

    {:reply, info, state}
  end

  # One pass (specs/04 §The pass). Nothing to drain or evict yet: the
  # policy, expiry and read-buffer steps are added by the tasks that own them.
  @spec pass(state()) :: state()
  defp pass(state) do
    started = System.monotonic_time()
    %{state | passes: state.passes + 1, last_pass_duration: System.monotonic_time() - started}
  end
end
