import Config

# Theine.Clock.now/1 expands to Theine.Test.Clock.now(cache) in the test
# build: the per-cache Agent clock when a test registered one, else the real
# monotonic clock (specs/06 §Clock).
config :theine, clock: Theine.Test.Clock
