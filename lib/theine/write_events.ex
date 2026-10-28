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
  depth of the write-event queue.

  Backpressure (specs/03 §Delivery with backpressure): while `pending` is at
  most `write_hwm` the event is a plain `send/2`; above it the writer makes a
  `GenServer.call/3` with no timeout and returns only once the maintenance
  process has consumed the event. The write itself has already happened and
  is never dropped; the writer just pays the maintenance process's lag, as a
  producer does on Caffeine's full write buffer. The mailbox therefore never
  holds more than `write_hwm` plain events plus one call per blocked writer.
  """

  alias Theine.{Config, Entry}

  @type event ::
          {:put, Entry.key(), Entry.id(), Entry.weight(), Entry.expires_at()}
          | {:removed, Entry.key(), Entry.id()}

  @doc """
  Counts `event` in `pending` and delivers it to the cache's maintenance
  process: by `send/2` while `pending` is at most `write_hwm`, otherwise by a
  call that returns once the event has been consumed. Returns `:ok`.
  """
  @spec deliver(Config.t(), event()) :: :ok
  def deliver(%Config{pending: pending, maintenance: maintenance, write_hwm: hwm}, event) do
    if :atomics.add_get(pending, 1, 1) <= hwm do
      send(maintenance, event)
      :ok
    else
      GenServer.call(maintenance, {:event, event}, :infinity)
    end
  end
end
