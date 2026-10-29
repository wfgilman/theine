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

  `deliver/2` never crashes the writer (specs/03 §Delivery with
  backpressure). While the maintenance process restarts its name is
  unregistered, so `send/2` raises `ArgumentError`, and a call in flight
  exits when the process dies; both are caught and `:ok` returned. The lost
  event is harmless: the mutation preceded the send, and the restarted
  process rebuilds its policy from the entries table after it registers
  (specs/04 §Restart semantics).
  """

  alias Theine.{Config, Entry}

  @type event ::
          {:put, Entry.key(), Entry.id(), Entry.weight(), Entry.expires_at()}
          | {:removed, Entry.key(), Entry.id()}

  @doc """
  Counts `event` in `pending` and delivers it to the cache's maintenance
  process: by `send/2` while `pending` is at most `write_hwm`, otherwise by a
  call that returns once the event has been consumed. Returns `:ok`, also
  when the maintenance process is restarting and the event is lost.
  """
  @spec deliver(Config.t(), event()) :: :ok
  def deliver(%Config{pending: pending, maintenance: maintenance, write_hwm: hwm}, event) do
    if :atomics.add_get(pending, 1, 1) <= hwm do
      send_event(maintenance, event)
    else
      call_event(maintenance, event)
    end
  end

  # `send/2` to a name that is not registered raises `ArgumentError`.
  defp send_event(maintenance, event) do
    send(maintenance, event)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # The call exits with `:noproc` when the name is not registered and with
  # the process's exit reason when it dies before replying.
  defp call_event(maintenance, event) do
    GenServer.call(maintenance, {:event, event}, :infinity)
  catch
    :exit, _reason -> :ok
  end
end
