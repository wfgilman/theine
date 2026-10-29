defmodule Theine.Test.Policy do
  @moduledoc """
  An instrumented `Theine.Policy` (specs/10 §Required helpers): every call
  the maintenance process makes is forwarded to the real policy, and its
  name is sent, in call order, to the process that registered itself with
  `listen/1` for that cache. A cache uses it when started with
  `policy_module: Theine.Test.Policy, test_hooks: true`.

      Theine.Test.Policy.listen(cache)
      start_supervised!({Theine, name: cache, max_size: 100, test_hooks: true,
                         policy_module: Theine.Test.Policy})
      ...
      Theine.Maintenance.info(cache)   # sync with the process
      Theine.Test.Policy.calls(cache)  #=> [:new, :on_write, :on_access, :evict]

  Without a listener the calls are forwarded and nothing is recorded.
  """

  alias Theine.{Config, Policy}

  @type call :: :new | :on_write | :on_remove | :on_access | :evict | :reset

  @doc "Registers the caller as the listener for `cache`'s policy calls."
  @spec listen(Config.cache()) :: :ok
  def listen(cache) when is_atom(cache) do
    true = Process.register(self(), name(cache))
    :ok
  end

  @doc "The registered name of `cache`'s listener."
  @spec name(Config.cache()) :: atom()
  def name(cache) when is_atom(cache), do: Module.concat(__MODULE__, cache)

  @doc """
  The calls recorded so far for `cache`, in order, taken out of the
  caller's mailbox. Call `Theine.Maintenance.info/1` first to be sure the
  process has finished what it was doing.
  """
  @spec calls(Config.cache()) :: [call()]
  def calls(cache) when is_atom(cache) do
    receive do
      {__MODULE__, ^cache, call} -> [call | calls(cache)]
    after
      0 -> []
    end
  end

  @spec new(Config.t()) :: Policy.t()
  def new(%Config{name: cache} = config) do
    record(cache, :new)
    Policy.new(config)
  end

  @spec on_write(Policy.t(), term(), pos_integer(), pos_integer(), integer() | :infinity) ::
          Policy.t()
  def on_write(%Policy{table: cache} = state, key, id, weight, expires_at) do
    record(cache, :on_write)
    Policy.on_write(state, key, id, weight, expires_at)
  end

  @spec on_remove(Policy.t(), term(), pos_integer()) :: Policy.t()
  def on_remove(%Policy{table: cache} = state, key, id) do
    record(cache, :on_remove)
    Policy.on_remove(state, key, id)
  end

  @spec on_access(Policy.t(), pos_integer()) :: Policy.t()
  def on_access(%Policy{table: cache} = state, id) do
    record(cache, :on_access)
    Policy.on_access(state, id)
  end

  @spec evict(Policy.t()) :: {:done | :more, non_neg_integer(), Policy.t()}
  def evict(%Policy{table: cache} = state) do
    record(cache, :evict)
    Policy.evict(state)
  end

  @spec reset(Policy.t()) :: Policy.t()
  def reset(%Policy{table: cache} = state) do
    record(cache, :reset)
    Policy.reset(state)
  end

  # The policy's `table` is the cache name (`Config.table`), so every call
  # knows which listener to tell.
  defp record(cache, call) do
    case Process.whereis(name(cache)) do
      nil -> :ok
      pid -> send(pid, {__MODULE__, cache, call})
    end

    :ok
  end
end
