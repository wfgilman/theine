defmodule Theine do
  @moduledoc """
  A bounded in-memory cache for the BEAM, modelled on Java's Caffeine.

  Entries live in ETS; access buffers and the frequency sketch live in
  `:atomics`; one maintenance process per cache owns the W-TinyLFU policy.
  The public API is specified in `specs/08-api-and-lifecycle.md`.
  """
end
