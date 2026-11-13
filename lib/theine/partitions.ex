defmodule Theine.Partitions do
  @moduledoc """
  The `one_for_one` supervisor of a partitioned cache's `n` maintenance
  processes (specs/12 §Supervision), the last child of `Theine.Supervisor`
  when `partitions` is greater than 1:

      Theine.Supervisor (rest_for_one)
      ├── Theine.Owner
      ├── Task.Supervisor
      └── Theine.Partitions     one_for_one
          ├── Theine.Maintenance partition 0   Theine.Maintenance.<cache>
          ├── Theine.Maintenance partition 1   Theine.Maintenance.<cache>.Partition1
          └── ...

  A crash in partition `p` restarts partition `p` only, which rebuilds
  from the entries table the entries whose id carries `p` (specs/12
  §Restart); under a flat `rest_for_one` it would also restart every
  partition after it. An Owner crash still restarts this supervisor and
  so every partition. The child id of partition `p` is
  `{Theine.Maintenance, p}`.
  """

  use Supervisor

  alias Theine.Config

  @doc "Registered name of the partitions supervisor of `cache`."
  @spec name(Config.cache()) :: atom()
  def name(cache) when is_atom(cache), do: Module.concat(__MODULE__, cache)

  @doc false
  @spec start_link(Config.t()) :: Supervisor.on_start()
  def start_link(%Config{} = config) do
    Supervisor.start_link(__MODULE__, config, name: name(config.name))
  end

  @impl true
  def init(%Config{name: cache, partitions: n}) do
    children =
      for p <- 0..(n - 1)//1 do
        Supervisor.child_spec({Theine.Maintenance, {cache, p}}, id: {Theine.Maintenance, p})
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
