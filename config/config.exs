import Config

# Only the test build injects a clock (specs/06 §Clock). This file is read
# when theine is compiled as the root project; a consumer's build never sees
# it, so `Theine.Clock.now/1` compiles to the BIF there.
if config_env() == :test do
  import_config "test.exs"
end
