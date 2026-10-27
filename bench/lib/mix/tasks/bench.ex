defmodule Mix.Tasks.Bench do
  @shortdoc "Runs bench/<name>.exs and fails when a threshold fails"

  @moduledoc """
  Runs one benchmark script from `bench/` (specs/09).

      ERL_FLAGS="+sbt db +sbwt very_long" mix bench get [script options]

  The script is evaluated with the remaining arguments in `System.argv/0` and
  must evaluate to the list of failed threshold descriptions. An empty list
  exits 0; anything else exits non-zero so the build loop sees a failed gate.

  This task lives under `bench/lib`, which is compiled only in `:dev`
  (`mix.exs` `elixirc_paths/1`), so it never ships in the hex package.
  """

  use Mix.Task

  # bench/traces.exs is the trace manifest, not a benchmark.
  @impl Mix.Task
  def run(["traces" | _argv]),
    do: Mix.raise("mix bench: traces is a manifest; run mix bench.traces")

  def run([name | argv]) do
    path = Path.join("bench", name <> ".exs")

    unless File.regular?(path) do
      Mix.raise("mix bench: no benchmark #{inspect(name)} (expected #{path})")
    end

    Mix.Task.run("app.start")
    System.argv(argv)

    case Code.eval_file(path) do
      {[], _binding} ->
        :ok

      {failures, _binding} when is_list(failures) ->
        Mix.raise("mix bench #{name}: #{length(failures)} threshold(s) failed")

      {other, _binding} ->
        Mix.raise("mix bench #{name}: script returned #{inspect(other)}, expected a list")
    end
  end

  def run([]), do: Mix.raise("usage: mix bench <name> [options], e.g. mix bench get")
end
