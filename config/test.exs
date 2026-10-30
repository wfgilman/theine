import Config

# Theine.Clock.now/1 expands to Theine.Test.Clock.now(cache) in the test
# build: the per-cache Agent clock when a test registered one, else the real
# monotonic clock (specs/06 §Clock).
config :theine, clock: Theine.Test.Clock

# Theine.Loader pauses a fetcher at the points a test arms, so claimants
# and waiters can be interleaved step by step (specs/07 §Decisions M4.2).
# Other builds compile the pause points to :ok.
config :theine, loader_hook: Theine.Test.LoaderHook
