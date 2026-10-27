defmodule Theine.Bench.Load do
  @moduledoc """
  Load drivers for `mix bench maintenance` (specs/09 §`mix bench maintenance`).
  They know nothing about theine: a subject is a map of callbacks, so the
  drivers can be checked against a plain ETS table before the cache exists.

      %{
        name: String.t(),
        start: (keyword() -> state),        # [max_size: n, write_hwm: n]
        put: (state, key, value, ttl_ms | nil -> any()),
        get: (state, key -> any()),
        size: (state -> non_neg_integer()), # :ets.info(entries, :size)
        call_writes: (state -> non_neg_integer() | nil),
        stop: (state -> any())
      }

  `call_writes` returns how many writes so far took the call path
  (specs/03 §Delivery with backpressure), or `nil` when the subject cannot
  tell.
  """

  alias Theine.Bench.Zipf

  @pass_event [:theine, :maintenance, :pass]
  @key_samples 65_536

  @doc """
  The overshoot run: `writers` processes put distinct keys for `duration_ms`
  while one process samples `subject.size` every `sample_ms`. After the
  writers stop it waits `settle_ms` and samples once more.
  """
  @spec write_run(map(), term(), keyword()) :: %{
          samples: [non_neg_integer()],
          max_sample: non_neg_integer(),
          writes: non_neg_integer(),
          settled_size: non_neg_integer()
        }
  def write_run(subject, state, opts) do
    writers = Keyword.fetch!(opts, :writers)
    sample_ms = Keyword.fetch!(opts, :sample_ms)
    stop = new_stop()

    sampler = spawn_link(fn -> sample_loop(subject, state, stop, sample_ms, []) end)

    pids =
      for i <- 1..writers do
        spawn_link(fn -> write_loop(subject, state, stop, i, writers, 0) end)
      end

    Process.sleep(Keyword.fetch!(opts, :duration_ms))
    stop(stop)

    writes = pids |> collect(:writes) |> Enum.sum()
    [samples] = collect([sampler], :samples)
    Process.sleep(Keyword.fetch!(opts, :settle_ms))

    %{
      samples: samples,
      max_sample: Enum.max(samples, fn -> 0 end),
      writes: writes,
      settled_size: subject.size.(state)
    }
  end

  # Writer i of w puts keys i, i + w, i + 2w, ...: distinct across the run.
  defp write_loop(subject, state, stop, key, step, writes) do
    if stopped?(stop) do
      reply(stop, :writes, writes)
    else
      subject.put.(state, key, key, nil)
      write_loop(subject, state, stop, key + step, step, writes + 1)
    end
  end

  defp sample_loop(subject, state, stop, sample_ms, acc) do
    acc = [subject.size.(state) | acc]

    if stopped?(stop) do
      reply(stop, :samples, Enum.reverse(acc))
    else
      Process.sleep(sample_ms)
      sample_loop(subject, state, stop, sample_ms, acc)
    end
  end

  @doc """
  The mixed run: keys `1..max_size` are put first, then `workers` processes
  run for `duration_ms`, each operation a `get` with probability
  `read_fraction` and otherwise a `put`, half of the puts with `ttl_ms`.
  Keys are Zipf(`zipf_s`) over `key_space`. Every `[:theine, :maintenance,
  :pass]` event during the run is collected.
  """
  @spec mixed_run(map(), term(), keyword()) :: %{
          pass_durations_us: [float()],
          reads: non_neg_integer(),
          writes: non_neg_integer(),
          call_writes: non_neg_integer() | nil
        }
  def mixed_run(subject, state, opts) do
    workers = Keyword.fetch!(opts, :workers)
    max_size = Keyword.fetch!(opts, :max_size)
    zipf = Zipf.new(Keyword.fetch!(opts, :key_space), Keyword.fetch!(opts, :zipf_s))
    keys = zipf |> Zipf.take(@key_samples, Keyword.fetch!(opts, :seed)) |> List.to_tuple()
    params = {Keyword.fetch!(opts, :read_fraction), Keyword.fetch!(opts, :ttl_ms)}

    Enum.each(1..max_size//1, &subject.put.(state, &1, &1, nil))

    calls_before = subject.call_writes.(state)
    passes = :ets.new(:theine_bench_passes, [:duplicate_bag, :public])
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, @pass_event, &__MODULE__.record_pass/4, passes)
    stop = new_stop()

    try do
      pids =
        for i <- 1..workers do
          spawn_link(fn ->
            mixed_loop(subject, state, stop, keys, params, Zipf.seed(i), {0, 0})
          end)
        end

      Process.sleep(Keyword.fetch!(opts, :duration_ms))
      stop(stop)
      {reads, writes} = pids |> collect(:ops) |> Enum.unzip()

      %{
        pass_durations_us: for({:pass, us} <- :ets.tab2list(passes), do: us),
        reads: Enum.sum(reads),
        writes: Enum.sum(writes),
        call_writes: delta(subject.call_writes.(state), calls_before)
      }
    after
      :telemetry.detach(handler)
      :ets.delete(passes)
    end
  end

  @doc false
  def record_pass(_event, %{duration: native}, _metadata, passes) do
    :ets.insert(passes, {:pass, :erlang.convert_time_unit(native, :native, :nanosecond) / 1000})
  end

  defp mixed_loop(subject, state, stop, keys, params, rand, {reads, writes} = ops) do
    if stopped?(stop) do
      reply(stop, :ops, ops)
    else
      {read_fraction, ttl_ms} = params
      {i, rand} = :rand.uniform_s(tuple_size(keys), rand)
      {op, rand} = :rand.uniform_s(rand)
      key = elem(keys, i - 1)

      cond do
        op < read_fraction ->
          subject.get.(state, key)
          mixed_loop(subject, state, stop, keys, params, rand, {reads + 1, writes})

        # The upper half of the write band carries the TTL: 50% of writes.
        op < (1 + read_fraction) / 2 ->
          subject.put.(state, key, key, nil)
          mixed_loop(subject, state, stop, keys, params, rand, {reads, writes + 1})

        true ->
          subject.put.(state, key, key, ttl_ms)
          mixed_loop(subject, state, stop, keys, params, rand, {reads, writes + 1})
      end
    end
  end

  defp delta(nil, _before), do: nil
  defp delta(_after, nil), do: nil
  defp delta(after_, before), do: after_ - before

  # A run's stop handle: the driving process and a flag every worker polls.
  defp new_stop, do: {self(), :atomics.new(1, [])}
  defp stop({_owner, flag}), do: :atomics.put(flag, 1, 1)
  defp stopped?({_owner, flag}), do: :atomics.get(flag, 1) == 1
  defp reply({owner, _flag}, tag, value), do: send(owner, {tag, self(), value})

  defp collect(pids, tag) do
    Enum.map(pids, fn pid ->
      receive do
        {^tag, ^pid, value} -> value
      end
    end)
  end

  @doc """
  The `p`th percentile (0..100) of `values` by nearest rank, or `nil` for an
  empty list.
  """
  @spec percentile([number()], number()) :: number() | nil
  def percentile([], _p), do: nil

  def percentile(values, p) when p >= 0 and p <= 100 do
    sorted = Enum.sort(values)
    rank = max(1, ceil(p / 100 * length(sorted)))
    Enum.at(sorted, rank - 1)
  end
end
