defmodule Theine.Supervisor do
  @moduledoc """
  The per-cache supervision tree (specs/08 §Supervision tree):

      Theine.Supervisor (rest_for_one)
      ├── Theine.Owner        tables, atomics, counters; writes the config
      ├── Task.Supervisor     async loads and refreshes
      └── Theine.Maintenance  the policy process

  `rest_for_one` so that losing the Owner (and with it the tables) restarts
  everything after it, while a Maintenance crash restarts only Maintenance.
  Each process is registered under an atom derived from the cache name, see
  `name/1`, `Theine.Owner.name/1` and `Theine.Maintenance.name/1`.

  With `partitions: n > 1` the last child is `Theine.Partitions`, a
  `one_for_one` supervisor of the `n` maintenance processes (specs/12
  §Supervision).
  """

  use Supervisor

  alias Theine.Config

  @doc "Registered name of the supervisor of `cache`."
  @spec name(Config.cache()) :: atom()
  def name(cache) when is_atom(cache), do: Module.concat(__MODULE__, cache)

  @doc false
  @spec start_link(Config.t()) :: Supervisor.on_start()
  def start_link(%Config{} = config) do
    Supervisor.start_link(__MODULE__, config, name: name(config.name))
  end

  @impl true
  def init(%Config{} = config) do
    children = [
      {Theine.Owner, config},
      Supervisor.child_spec({Task.Supervisor, name: config.task_supervisor},
        id: Theine.TaskSupervisor
      ),
      maintenance(config)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # One partition keeps the tree above; more get their own `one_for_one`
  # supervisor, so a crash in one partition restarts that one only
  # (specs/12 §Supervision).
  defp maintenance(%Config{partitions: 1, name: cache}), do: {Theine.Maintenance, cache}
  defp maintenance(%Config{} = config), do: {Theine.Partitions, config}
end
