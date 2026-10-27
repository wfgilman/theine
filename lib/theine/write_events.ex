defmodule Theine.WriteEvents do
  @moduledoc """
  Delivery of write events to the maintenance process (specs/03 §Write
  events).

  Writes cannot be lossy, and they carry the key, so they travel as messages:

      {:put, key, id, weight, expires_at}   a new version of key was inserted
      {:removed, key, id}                   key version id was deleted

  Every event is sent *after* the ETS mutation it describes. The writer
  counts the event in the `pending` atomic before sending it and the
  maintenance process decrements it per consumed event, so `pending` is the
  depth of the write-event queue. The backpressure path above `write_hwm`
  (a `GenServer.call/3` instead of `send/2`) arrives in M1.3.
  """

  alias Theine.{Config, Entry}

  @type event ::
          {:put, Entry.key(), Entry.id(), Entry.weight(), Entry.expires_at()}
          | {:removed, Entry.key(), Entry.id()}

  @doc """
  Counts `event` in `pending` and sends it to the cache's maintenance
  process. Returns `:ok`.
  """
  @spec deliver(Config.t(), event()) :: :ok
  def deliver(%Config{pending: pending, maintenance: maintenance}, event) do
    _ = :atomics.add_get(pending, 1, 1)
    send(maintenance, event)
    :ok
  end
end
