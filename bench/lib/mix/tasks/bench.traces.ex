defmodule Mix.Tasks.Bench.Traces do
  @shortdoc "Downloads, generates and verifies the hit-rate traces in bench/traces/"

  @moduledoc """
  Populates `bench/traces/` with every trace listed in `bench/traces.exs`
  (specs/09 §`mix bench hitrate`).

      mix bench.traces                  # every trace
      mix bench.traces --only loop,zipf # a subset, by name

  ARC traces are downloaded from the URL recorded in the manifest; synthetic
  traces are generated from a fixed seed. Each file is checked against the
  SHA-256 recorded in the manifest. A file already present with the right
  hash is left alone, so re-running is a no-op.

  Exits non-zero, naming the trace, when a trace has no URL, its download
  fails, or its hash does not match (or none is recorded yet, in which case
  the message gives the hash to record).

  Options `--manifest` and `--dir` point at another manifest and directory.

  Like `mix bench`, this task lives under `bench/lib` and is compiled in
  `:dev` only.
  """

  use Mix.Task

  alias Theine.Bench.Traces

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [only: :string, manifest: :string, dir: :string])

    manifest = Traces.manifest(Keyword.get(opts, :manifest, Traces.default_manifest()))
    dir = Keyword.get(opts, :dir, Traces.default_dir())
    entries = select(manifest, opts[:only])

    failures =
      for entry <- entries, reduce: [] do
        failures ->
          {micros, status} = :timer.tc(fn -> Traces.ensure(entry, dir) end)
          report(entry, status, micros, dir)
          if match?({:error, _}, status), do: [status | failures], else: failures
      end

    case Enum.reverse(failures) do
      [] ->
        :ok

      failures ->
        names = Enum.map_join(failures, "\n  ", fn {:error, message} -> message end)
        Mix.raise("mix bench.traces: #{length(failures)} trace(s) failed:\n  " <> names)
    end
  end

  defp select(manifest, nil), do: manifest

  defp select(manifest, csv) do
    wanted = csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    known = Enum.map(manifest, & &1.name)

    case wanted -- known do
      [] -> Enum.filter(manifest, &(&1.name in wanted))
      unknown -> Mix.raise("mix bench.traces: unknown trace(s) #{Enum.join(unknown, ", ")}")
    end
  end

  defp report(entry, status, micros, dir) do
    seconds = Float.round(micros / 1_000_000, 1)
    path = Traces.path(entry, dir)

    case status do
      :ok -> Mix.shell().info("#{entry.name}: ok (#{path})")
      :fetched -> Mix.shell().info("#{entry.name}: downloaded and verified in #{seconds} s")
      :generated -> Mix.shell().info("#{entry.name}: generated and verified in #{seconds} s")
      {:error, message} -> Mix.shell().error(message)
    end
  end
end
