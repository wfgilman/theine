defmodule Theine.Bench.NebulexCache do
  @moduledoc false
  # The `nebulex` subject of `mix bench get` (specs/09): a Nebulex 3 cache on
  # the generational local adapter. Options come from `start_link/1`, so
  # there is no application config for it.

  use Nebulex.Cache, otp_app: :theine, adapter: Nebulex.Adapters.Local
end
