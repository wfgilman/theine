defmodule Theine.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Caches are started by the host application under its own supervisor
    # (`Theine.start_link/1`); this tree is intentionally empty.
    Supervisor.start_link([], strategy: :one_for_one, name: Theine.AppSupervisor)
  end
end
