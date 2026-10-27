defmodule Theine.Bench.Traces do
  @moduledoc """
  The hit-rate traces (specs/09 §`mix bench hitrate`): the manifest in
  `bench/traces.exs`, downloading and verifying the ARC traces, and generating
  the synthetic ones.

  Every trace ends up as one file in `bench/traces/` whose SHA-256 is recorded
  in the manifest. For a downloaded trace the hash is of the stored file, after
  decompression, so a re-run can verify what is on disk without the original
  archive. Synthetic traces are generated from a fixed seed and checked against
  their recorded hash the same way, which also catches a generator that stops
  being deterministic.

  Formats on disk:

    * `:arc` — the ARC `.lis` format, one request per line,
      `start_block block_count ignored request_id`.
    * `:keys` — one non-negative decimal key per line.
  """

  alias Theine.Bench.Zipf

  @manifest "bench/traces.exs"
  @dir "bench/traces"
  @chunk 1_048_576
  @gen_chunk 100_000

  @type entry :: %{
          required(:name) => String.t(),
          required(:file) => String.t(),
          required(:format) => :arc | :keys,
          required(:sizes) => [pos_integer()],
          required(:sha256) => String.t() | nil,
          optional(:url) => String.t() | nil,
          optional(:compression) => :none | :gzip | :zstd,
          optional(:generator) => {:loop | :zipf, keyword()}
        }

  @type status :: :ok | :fetched | :generated | {:error, String.t()}

  def default_manifest, do: @manifest
  def default_dir, do: @dir

  @doc "Reads and validates the manifest; raises on a malformed entry."
  @spec manifest(Path.t()) :: [entry()]
  def manifest(path \\ @manifest) do
    {entries, _binding} = Code.eval_file(path)

    unless is_list(entries), do: raise(ArgumentError, "#{path} must evaluate to a list")
    Enum.each(entries, &validate!(&1, path))
    entries
  end

  @doc "Path of a trace's file in `dir`."
  @spec path(entry(), Path.t()) :: Path.t()
  def path(%{file: file}, dir \\ @dir), do: Path.join(dir, file)

  @doc """
  Makes one trace present and verified in `dir`.

  An existing file with the recorded hash is left alone (`:ok`), so re-running
  is a no-op. Otherwise the trace is downloaded or generated into a `.part`
  file, hashed, and renamed into place only when the hash matches.
  """
  @spec ensure(entry(), Path.t()) :: status()
  def ensure(entry, dir \\ @dir) do
    File.mkdir_p!(dir)
    final = path(entry, dir)

    cond do
      entry.sha256 && File.regular?(final) && sha256_file(final) == entry.sha256 -> :ok
      Map.has_key?(entry, :generator) -> produce(entry, final, :generated)
      true -> produce(entry, final, :fetched)
    end
  end

  defp produce(%{url: nil} = entry, _final, :fetched) do
    {:error, "#{entry.name}: no URL recorded in the manifest"}
  end

  defp produce(entry, final, done) do
    part = final <> ".part"
    File.rm(part)

    result =
      case done do
        :generated -> generate(entry.generator, part)
        :fetched -> fetch(entry, part)
      end

    with :ok <- result,
         actual = sha256_file(part),
         :ok <- check_hash(entry, actual) do
      File.rename!(part, final)
      done
    else
      {:error, reason} ->
        File.rm(part)
        {:error, "#{entry.name}: #{reason}"}
    end
  end

  defp check_hash(%{sha256: expected}, expected), do: :ok

  defp check_hash(%{sha256: nil}, actual) do
    {:error, "no SHA-256 recorded in the manifest; the produced file hashes to #{actual}"}
  end

  defp check_hash(%{sha256: expected}, actual) do
    {:error, "SHA-256 mismatch: expected #{expected}, got #{actual}"}
  end

  ## Download

  defp fetch(entry, part) do
    download = part <> ".download"
    File.rm(download)

    try do
      with :ok <- download(entry.url, download) do
        decompress(Map.get(entry, :compression, :none), download, part)
      end
    after
      File.rm(download)
    end
  end

  # `file://` is accepted so a trace already on disk can be installed (and so
  # the task can be exercised without a network).
  defp download("file://" <> source, dest) do
    case File.cp(source, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot read #{source}: #{:file.format_error(reason)}"}
    end
  end

  defp download(url, dest) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    http = [
      autoredirect: true,
      timeout: :timer.minutes(30),
      connect_timeout: :timer.seconds(30),
      ssl: :httpc.ssl_verify_host_options(true)
    ]

    request = {String.to_charlist(url), [{~c"user-agent", ~c"theine-bench"}]}

    case :httpc.request(:get, request, http, stream: String.to_charlist(dest)) do
      {:ok, :saved_to_file} -> :ok
      {:ok, {{_, status, reason}, _headers, _body}} -> {:error, "GET #{url}: #{status} #{reason}"}
      {:error, reason} -> {:error, "GET #{url}: #{inspect(reason)}"}
    end
  end

  defp decompress(:none, source, dest), do: File.rename(source, dest)

  defp decompress(:gzip, source, dest) do
    z = :zlib.open()
    # 16 + MAX_WBITS: gzip header and trailer.
    :ok = :zlib.inflateInit(z, 31)

    try do
      finish = fn ->
        :ok = :zlib.inflateEnd(z)
        []
      end

      transform(source, dest, &:zlib.inflate(z, &1), finish)
    rescue
      e in ErlangError -> {:error, "gunzip failed: #{inspect(e.original)}"}
    after
      :zlib.close(z)
    end
  end

  defp decompress(:zstd, source, dest) do
    {:ok, ctx} = :zstd.context(:decompress)

    step = fn data -> zstd_stream(ctx, data, []) end

    finish = fn ->
      {:done, out} = :zstd.finish(ctx, <<>>)
      out
    end

    try do
      transform(source, dest, step, finish)
    rescue
      e in [ErlangError, MatchError, CaseClauseError] ->
        {:error, "zstd decompression failed: #{Exception.message(e)}"}
    after
      :zstd.close(ctx)
    end
  end

  # The context consumes input only as fast as its output buffer drains, and
  # hands back the unconsumed remainder to feed again.
  defp zstd_stream(ctx, data, acc) do
    case :zstd.stream(ctx, data) do
      {:continue, out} -> [acc, out]
      {:continue, remainder, out} -> zstd_stream(ctx, remainder, [acc, out])
    end
  end

  defp transform(source, dest, step, finish) do
    File.open!(dest, [:write, :raw, :binary, {:delayed_write, @chunk, 1_000}], fn out ->
      source
      |> File.stream!(@chunk)
      |> Enum.each(&IO.binwrite(out, step.(&1)))

      IO.binwrite(out, finish.())
    end)

    :ok
  end

  ## Synthetic traces

  @doc """
  Writes a synthetic trace in the `:keys` format.

    * `{:loop, keys: k, cycles: c}` — `0..k-1` in order, `c` times.
    * `{:zipf, s: s, keys: k, requests: r, seed: seed}` — `r` draws from
      Zipf(`s`) over `1..k` (`Theine.Bench.Zipf`, rank 1 most frequent).
  """
  @spec generate({:loop | :zipf, keyword()}, Path.t()) :: :ok
  def generate({:loop, opts}, dest) do
    keys = Keyword.fetch!(opts, :keys)
    cycles = Keyword.fetch!(opts, :cycles)
    cycle = Enum.map(0..(keys - 1), &[Integer.to_string(&1), ?\n])

    write_keys(dest, fn out -> for _ <- 1..cycles, do: IO.binwrite(out, cycle) end)
  end

  def generate({:zipf, opts}, dest) do
    zipf = Zipf.new(Keyword.fetch!(opts, :keys), Keyword.fetch!(opts, :s))
    requests = Keyword.fetch!(opts, :requests)

    write_keys(dest, fn out ->
      Enum.reduce(chunks(requests), Zipf.seed(Keyword.fetch!(opts, :seed)), fn count, rand ->
        {lines, rand} =
          Enum.map_reduce(1..count, rand, fn _, rand ->
            {key, rand} = Zipf.sample(zipf, rand)
            {[Integer.to_string(key), ?\n], rand}
          end)

        IO.binwrite(out, lines)
        rand
      end)
    end)
  end

  defp chunks(total) do
    full = div(total, @gen_chunk)
    rest = rem(total, @gen_chunk)
    List.duplicate(@gen_chunk, full) ++ if(rest > 0, do: [rest], else: [])
  end

  defp write_keys(dest, fun) do
    File.open!(dest, [:write, :raw, :binary, {:delayed_write, @chunk, 1_000}], fun)
    :ok
  end

  ## Hashing

  @doc "Lower-case hex SHA-256 of a file, streamed."
  @spec sha256_file(Path.t()) :: String.t()
  def sha256_file(path) do
    path
    |> File.stream!(@chunk)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  ## Validation

  defp validate!(%{name: name, file: file, format: format, sizes: sizes} = entry, _path)
       when is_binary(name) and is_binary(file) and format in [:arc, :keys] and
              is_list(sizes) do
    sha = Map.get(entry, :sha256)

    unless is_nil(sha) or (is_binary(sha) and byte_size(sha) == 64) do
      raise ArgumentError, "#{name}: :sha256 must be nil or 64 hex characters"
    end

    case entry do
      %{generator: {kind, opts}} when kind in [:loop, :zipf] and is_list(opts) ->
        :ok

      %{url: url} when is_nil(url) or is_binary(url) ->
        unless Map.get(entry, :compression, :none) in [:none, :gzip, :zstd] do
          raise ArgumentError, "#{name}: :compression must be :none, :gzip or :zstd"
        end

      _ ->
        raise ArgumentError, "#{name}: needs either :url or :generator"
    end
  end

  defp validate!(entry, path) do
    raise ArgumentError,
          "#{path}: entry needs :name, :file, :format and :sizes, got #{inspect(entry)}"
  end
end
