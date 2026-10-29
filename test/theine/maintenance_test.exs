defmodule Theine.MaintenanceTest do
  use ExUnit.Case, async: true

  import Theine.Test.Helpers

  alias Theine.{Config, Maintenance, ReadBuffer, Sketch}

  @drain_flag Theine.Owner.drain_flag()

  # A long interval keeps the timer out of the pass counts and mailbox
  # lengths asserted below; the timer has its own test.
  @quiet [maintenance_interval: 60_000]

  setup do
    cache = unique_cache()
    start_supervised!({Theine, [name: cache, max_size: :infinity] ++ @quiet})
    %{cache: cache}
  end

  defp flag(cache), do: :atomics.get(Config.get(cache).flags, @drain_flag)

  defp id_of(cache, key), do: :ets.lookup_element(cache, key, 3)

  defp seq_of(cache, key) do
    {:ok, {^key, _id, _segment, seq, _weight, _expires_at}} = Maintenance.policy_row(cache, key)
    seq
  end

  # Forwards every pass event of `cache` to the test process as
  # `{:pass, measurements, metadata, extra}`, with the emission time, the
  # maintenance process's own mailbox length and the drain flag as seen at
  # emission time.
  defp attach_pass_handler(cache) do
    handler = {__MODULE__, cache}
    config = %{test: self(), cache: cache, flags: Config.get(cache).flags}

    :ok =
      :telemetry.attach(
        handler,
        [:theine, :maintenance, :pass],
        &__MODULE__.handle_pass/4,
        config
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Only the attached cache's passes: the async tests' caches all emit the
  # same event, and a test that refutes a further pass must not see theirs.
  def handle_pass(_event, measurements, %{cache: cache} = metadata, %{cache: cache} = config) do
    at = System.monotonic_time()
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    flag = :atomics.get(config.flags, @drain_flag)
    send(config.test, {:pass, measurements, metadata, %{at: at, queue: len, flag: flag}})
  end

  def handle_pass(_event, _measurements, _metadata, _config), do: :ok

  defp ms(n), do: System.convert_time_unit(n, :millisecond, :native)

  # Reads `key` from `cache` as fast as it can until `deadline` (monotonic ms).
  defp flood(cache, key, deadline) do
    {:ok, _} = Theine.get(cache, key)
    if System.monotonic_time(:millisecond) < deadline, do: flood(cache, key, deadline), else: :ok
  end

  # Puts `key`, `key + step`, ... into `cache` as fast as it can until the
  # `stop` atomic is set, then exits normally.
  defp write_until(cache, stop, key, step) do
    if :atomics.get(stop, 1) == 0 do
      Theine.put(cache, key, key)
      write_until(cache, stop, key + step, step)
    else
      :ok
    end
  end

  # Every pass message of `cache` already in the test mailbox.
  defp passes_received(cache, acc \\ []) do
    receive do
      {:pass, measurements, %{cache: ^cache}, extra} ->
        passes_received(cache, [{measurements, extra} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "info/1 reports the cache, pass count, last pass duration, pending and sizes", %{
    cache: cache
  } do
    assert Maintenance.info(cache) == %{
             cache: cache,
             passes: 0,
             last_pass_duration: nil,
             pending: 0,
             call_writes: 0,
             size: 0,
             weighted_size: 0,
             segments: nil,
             read_buffer: nil,
             sketch: nil
           }

    :atomics.add(Config.get(cache).pending, 1, 3)
    assert Maintenance.info(cache).pending == 3
  end

  describe "info/1 call_writes (specs/03 §Decisions M2.11)" do
    @hwm 4

    setup do
      cache = unique_cache()

      start_supervised!(
        {Theine, [name: cache, max_size: :infinity, write_hwm: @hwm, test_hooks: true] ++ @quiet}
      )

      %{cache: cache, config: Config.get(cache)}
    end

    test "counts the events consumed as backpressure calls and not the sent ones", %{
      cache: cache,
      config: config
    } do
      for i <- 1..@hwm, do: :ok = Theine.put(cache, i, i)
      :ok = Maintenance.run(cache)
      assert %{call_writes: 0, pending: 0} = Maintenance.info(cache)

      # With `pending` held at the high-water mark every put takes the call
      # path: add_get gives hwm + 1, the process consumes it back to hwm.
      :atomics.add(config.pending, 1, @hwm)
      for i <- 1..3, do: :ok = Theine.put(cache, i, i)
      assert %{call_writes: 3, pending: @hwm} = Maintenance.info(cache)

      :atomics.sub(config.pending, 1, @hwm)
      :ok = Theine.put(cache, 1, 1)
      :ok = Maintenance.run(cache)
      assert %{call_writes: 3, pending: 0} = Maintenance.info(cache)
    end

    test "counts the calls a pass flushes from the mailbox", %{cache: cache, config: config} do
      maintenance = Process.whereis(Maintenance.name(cache))
      :ok = Maintenance.pause(cache)

      # Queue a run/1 call ahead of the writers' calls, so that the pass it
      # triggers consumes them in its step-1 flush rather than handle_call.
      runner = Task.async(fn -> Maintenance.run(cache) end)

      assert_eventually(fn ->
        Process.info(maintenance, :message_queue_len) == {:message_queue_len, 1}
      end)

      :atomics.add(config.pending, 1, @hwm)
      writers = for i <- 1..2, do: Task.async(fn -> Theine.put(cache, i, i) end)

      assert_eventually(fn ->
        Process.info(maintenance, :message_queue_len) == {:message_queue_len, 3}
      end)

      :ok = Maintenance.resume(cache)
      assert Task.await(runner) == :ok
      assert Enum.map(writers, &Task.await/1) == [:ok, :ok]

      assert %{call_writes: 2, passes: 1, pending: @hwm} = Maintenance.info(cache)
      :atomics.sub(config.pending, 1, @hwm)
    end

    test "reset/1 zeroes it", %{cache: cache, config: config} do
      :atomics.add(config.pending, 1, @hwm)
      :ok = Theine.put(cache, 1, 1)
      :atomics.sub(config.pending, 1, @hwm)
      assert %{call_writes: 1} = Maintenance.info(cache)

      :ok = Maintenance.reset(cache)
      assert %{call_writes: 0} = Maintenance.info(cache)
    end
  end

  test "init/1 seeds :rand from the cache name", %{cache: cache} do
    # :rand.seed/2 stores what seed_s/2 returns in the process dictionary,
    # so the admission guard's random draws are a function of the name
    # alone (specs/05 §Events `evict`).
    pid = Process.whereis(Maintenance.name(cache))
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    assert dictionary[:rand_seed] == :rand.seed_s(:exsss, Maintenance.rand_seed(cache))
    assert Maintenance.rand_seed(cache) != Maintenance.rand_seed(:another_name)
  end

  test "info/1 of a bounded cache reports segments, read buffer and sketch" do
    cache = unique_cache()

    start_supervised!(
      {Theine, [name: cache, max_size: 1_000, stripes: 2, read_buffer_slots: 8] ++ @quiet}
    )

    assert %{segments: %{window: 0, probation: 0, protected: 0}} = Maintenance.info(cache)
    assert %{read_buffer: %{stripes: 2, slots: 8, lag: 0}} = Maintenance.info(cache)
    assert %{sketch: %{words: 1024, increments: 0, reset: nil}} = Maintenance.info(cache)

    Theine.put(cache, :a, 1, weight: 3)
    Theine.put(cache, :b, 1)
    Theine.put(cache, :a, 2, weight: 4)
    Maintenance.run(cache)

    assert %{size: 2, weighted_size: 5, segments: %{window: 5, probation: 0, protected: 0}} =
             Maintenance.info(cache)

    assert %{sketch: %{increments: 3}} = Maintenance.info(cache)
    assert {:ok, {:a, _, :window, _, 4, :infinity}} = Maintenance.policy_row(cache, :a)

    # A read claimed in the buffer shows up as lag until a drain.
    config = Config.get(cache)
    :atomics.put(config.read_buffer, 1, 5)
    assert %{read_buffer: %{lag: 5}} = Maintenance.info(cache)
    Maintenance.run(cache)
    assert %{read_buffer: %{lag: 0}} = Maintenance.info(cache)
  end

  test "run/1 returns :ok after one pass and info/1 counts it", %{cache: cache} do
    assert Maintenance.run(cache) == :ok
    assert Maintenance.run(cache) == :ok

    info = Maintenance.info(cache)
    assert info.passes == 2
    assert is_integer(info.last_pass_duration) and info.last_pass_duration >= 0
  end

  test "reset/1 returns :ok and forgets the pass history and the policy rows", %{cache: cache} do
    Theine.put(cache, :a, 1, weight: 2)
    :ok = Maintenance.run(cache)
    assert %{size: 1, weighted_size: 2} = Maintenance.info(cache)

    assert Maintenance.reset(cache) == :ok

    assert %{passes: 0, last_pass_duration: nil, size: 0, weighted_size: 0} =
             Maintenance.info(cache)

    assert Maintenance.policy_row(cache, :a) == :error
  end

  test "init resets pending and the drain flag", %{cache: cache} do
    config = Config.get(cache)
    :atomics.put(config.pending, 1, 9)
    :atomics.put(config.flags, Theine.Owner.drain_flag(), 1)
    pid = Process.whereis(Maintenance.name(cache))

    Process.exit(pid, :kill)
    assert_eventually(fn -> Process.whereis(Maintenance.name(cache)) not in [nil, pid] end)

    assert :atomics.get(config.pending, 1) == 0
    assert :atomics.get(config.flags, Theine.Owner.drain_flag()) == 0
    assert :ets.info(cache, :owner) == Process.whereis(Theine.Owner.name(cache))
  end

  describe "write events" do
    test "a :put event adds a policy row and decrements pending", %{cache: cache} do
      config = Config.get(cache)
      name = Maintenance.name(cache)

      :atomics.add(config.pending, 1, 1)
      send(name, {:put, :a, 7, 2, :infinity})

      assert Maintenance.policy_row(cache, :a) == {:ok, {:a, 7, nil, 1, 2, :infinity}}
      assert %{pending: 0, size: 1, weighted_size: 2} = Maintenance.info(cache)
    end

    test "a :removed event with the current id removes the row, a stale one is ignored", %{
      cache: cache
    } do
      config = Config.get(cache)
      name = Maintenance.name(cache)
      :ets.insert(cache, {:a, 1, 7, 1, 0, :infinity})

      :atomics.add(config.pending, 1, 3)
      send(name, {:put, :a, 7, 1, :infinity})
      send(name, {:removed, :a, 6})
      assert Maintenance.policy_row(cache, :a) == {:ok, {:a, 7, nil, 1, 1, :infinity}}

      send(name, {:removed, :a, 7})
      assert Maintenance.policy_row(cache, :a) == :error
      assert %{pending: 0, size: 0, weighted_size: 0} = Maintenance.info(cache)
    end

    test "a stale :removed event drops the row once the entries table lacks the key", %{
      cache: cache
    } do
      # specs/05 §Decisions (M1.5): the table kept id 7, the policy applied
      # id 8 last; the delete of id 7 must still clear the row.
      config = Config.get(cache)
      name = Maintenance.name(cache)
      :ets.insert(cache, {:a, 1, 7, 1, 0, :infinity})

      :atomics.add(config.pending, 1, 3)
      send(name, {:put, :a, 7, 1, :infinity})
      send(name, {:put, :a, 8, 2, :infinity})
      assert Maintenance.policy_row(cache, :a) == {:ok, {:a, 8, nil, 1, 2, :infinity}}

      :ets.delete(cache, :a)
      send(name, {:removed, :a, 7})
      assert Maintenance.policy_row(cache, :a) == :error
      assert %{pending: 0, size: 0, weighted_size: 0} = Maintenance.info(cache)
    end

    test "events are applied without a pass", %{cache: cache} do
      for i <- 1..50, do: Theine.put(cache, i, i)
      assert %{passes: 0, size: 50, weighted_size: 50, pending: 0} = Maintenance.info(cache)
    end

    test "an {:event, _} call is consumed in mailbox order and replied to", %{cache: cache} do
      config = Config.get(cache)
      name = Maintenance.name(cache)
      :ets.insert(cache, {:a, 1, 8, 2, 0, :infinity})

      :atomics.add(config.pending, 1, 3)
      send(name, {:put, :a, 7, 1, :infinity})
      assert GenServer.call(name, {:event, {:put, :a, 8, 2, :infinity}}) == :ok
      assert GenServer.call(name, {:event, {:removed, :a, 7}}) == :ok

      # The stale removal arrived after the :put of id 8, which is live in
      # the table, and was ignored.
      assert Maintenance.policy_row(cache, :a) == {:ok, {:a, 8, nil, 1, 2, :infinity}}
      assert %{pending: 0, size: 1, weighted_size: 2} = Maintenance.info(cache)
    end
  end

  describe "pause/1 and resume/1" do
    test "raise ArgumentError without test_hooks", %{cache: cache} do
      assert_raise ArgumentError, ~r/test_hooks: true/, fn -> Maintenance.pause(cache) end
      assert_raise ArgumentError, ~r/test_hooks: true/, fn -> Maintenance.resume(cache) end
      assert Maintenance.info(cache).passes == 0
    end

    test "a paused process consumes nothing until resume, then everything" do
      cache = unique_cache()
      start_supervised!({Theine, [name: cache, max_size: :infinity, test_hooks: true] ++ @quiet})
      pid = Process.whereis(Maintenance.name(cache))

      assert Maintenance.pause(cache) == :ok
      for i <- 1..10, do: Theine.put(cache, i, i)
      Process.sleep(20)

      assert :atomics.get(Config.get(cache).pending, 1) == 10
      assert Process.info(pid, :message_queue_len) == {:message_queue_len, 10}
      assert Theine.size(cache) == 0

      assert Maintenance.resume(cache) == :ok
      assert %{pending: 0, size: 10} = Maintenance.info(cache)
    end

    test "resume/1 on a running process is a no-op" do
      cache = unique_cache()
      start_supervised!({Theine, [name: cache, max_size: :infinity, test_hooks: true] ++ @quiet})

      assert Maintenance.resume(cache) == :ok
      Theine.put(cache, :a, 1)
      assert %{pending: 0, size: 1} = Maintenance.info(cache)
    end
  end

  describe "the pass (specs/04 §The pass)" do
    test "call order within one pass is writes, reads, evict" do
      cache = unique_cache()
      :ok = Theine.Test.Policy.listen(cache)

      # window_percent 50 keeps three entries in the window through evict's
      # window overflow, so the seqs below compare within one segment.
      start_supervised!(
        {Theine,
         [
           name: cache,
           max_size: 100,
           window_percent: 50,
           test_hooks: true,
           policy_module: Theine.Test.Policy
         ] ++ @quiet}
      )

      assert Theine.Test.Policy.calls(cache) == [:new]
      config = Config.get(cache)
      name = Maintenance.name(cache)

      # While paused: a :drain first, then three write events behind it, then
      # two reads in the buffer (below the threshold, and the flag is set
      # anyway, so they send nothing). The pass that handles the :drain must
      # apply the writes in step 1 before draining the reads in step 3, which
      # is observable because the reads are of ids the writes introduce.
      # Each applied :put evicts before it is consumed (specs/04 §The pass),
      # so an evict call sits inside every write; the pass's own comes last.
      :ok = Maintenance.pause(cache)
      :atomics.put(config.flags, @drain_flag, 1)
      send(name, :drain)
      for i <- 1..3, do: Theine.put(cache, i, i)
      :ok = ReadBuffer.record(config, id_of(cache, 1))
      :ok = ReadBuffer.record(config, id_of(cache, 2))
      :ok = Maintenance.resume(cache)

      assert %{passes: 1, pending: 0, size: 3} = Maintenance.info(cache)

      assert Theine.Test.Policy.calls(cache) ==
               [:on_write, :evict, :on_write, :evict, :on_write, :evict] ++
                 [:on_access, :on_access, :evict]

      # The reads were applied: keys 1 and 2 moved above key 3 in the window.
      assert seq_of(cache, 3) < seq_of(cache, 1)
      assert seq_of(cache, 1) < seq_of(cache, 2)
      assert flag(cache) == 0

      Theine.delete(cache, 3)
      Theine.clear(cache)
      Maintenance.info(cache)
      assert Theine.Test.Policy.calls(cache) == [:on_remove, :reset]
    end

    test "a :drain message clears the flag, drains the read buffer into the policy and evicts" do
      cache = unique_cache()
      # window_percent 50: a five-entry window, so the two keys stay in it.
      start_supervised!({Theine, [name: cache, max_size: 10, window_percent: 50] ++ @quiet})
      config = Config.get(cache)

      Theine.put(cache, :a, 1)
      Theine.put(cache, :b, 2)
      Maintenance.run(cache)
      assert seq_of(cache, :a) < seq_of(cache, :b)

      :ok = ReadBuffer.record(config, id_of(cache, :a))
      assert %{read_buffer: %{lag: 1}} = Maintenance.info(cache)
      :atomics.put(config.flags, @drain_flag, 1)
      send(Maintenance.name(cache), :drain)

      # The :drain follows the run/1 pass within drain_backoff × its
      # duration, so it is deferred by about a millisecond (§The pass).
      assert_eventually(fn ->
        assert %{passes: 2, read_buffer: %{lag: 0}} = Maintenance.info(cache)
      end)

      assert flag(cache) == 0
      assert seq_of(cache, :a) > seq_of(cache, :b)

      # Eviction runs every pass: 15 entries against max_size 10.
      for i <- 1..13, do: Theine.put(cache, i, i)
      Maintenance.run(cache)
      assert Theine.size(cache) == 10
      assert Theine.weighted_size(cache) == 10
      assert :ets.info(cache, :size) == 10
      assert Theine.stats(cache).evictions == 5
    end

    test "10_000 queued write events and a full read buffer: one pass consumes at most write_batch events and stripes * slots reads and schedules a follow-up" do
      cache = unique_cache()

      start_supervised!(
        {Theine,
         [name: cache, max_size: 20_000, stripes: 2, read_buffer_slots: 8, test_hooks: true] ++
           @quiet}
      )

      config = Config.get(cache)
      name = Maintenance.name(cache)
      attach_pass_handler(cache)

      # Paused: 100 reads fill the test process's stripe and send the one
      # :drain of specs/03; then 10_000 write events queue behind it.
      :ok = Maintenance.pause(cache)
      for i <- 1..100, do: :ok = ReadBuffer.record(config, i)
      assert flag(cache) == 1
      :atomics.add(config.pending, 1, 10_000)
      for i <- 1..10_000, do: send(name, {:put, i, i, 1, :infinity})
      :ok = Maintenance.resume(cache)

      # The first pass: 256 of the events in step 1 (the cap is write_batch,
      # specs/04 §Decisions M2.11d), at most 16 reads in step 3, and,
      # because a stripe was full, the follow-up :drain queued behind the
      # 9_744 events still in the mailbox with the flag set again.
      assert_receive {:pass, measurements, %{cache: ^cache}, %{queue: queue, flag: 1}}, 5_000
      assert measurements.writes == config.write_batch
      assert measurements.reads <= config.stripes * config.read_buffer_slots
      assert measurements.reads > 0
      assert queue == 10_000 - config.write_batch + 1

      # The rest drains through the write-count trigger and the follow-up.
      assert_eventually(fn -> Maintenance.info(cache).pending == 0 end, 5_000)
      assert %{size: 10_000, read_buffer: %{lag: 0}} = Maintenance.info(cache)
      assert Maintenance.info(cache).passes > 1
    end

    test "one pass telemetry event with all five measurements", %{cache: cache} do
      attach_pass_handler(cache)
      Theine.put(cache, :a, 1)
      Theine.put(cache, :b, 2)
      Theine.delete(cache, :a)
      Maintenance.run(cache)

      assert_receive {:pass, measurements, %{cache: ^cache}, _}
      assert %{duration: duration, reads: 0, writes: 3, expired: 0, evicted: 0} = measurements
      assert is_integer(duration) and duration >= 0
      assert map_size(measurements) == 5
      assert Maintenance.info(cache).last_pass_duration == duration

      # The write count is per pass: nothing since.
      Maintenance.run(cache)
      assert_receive {:pass, %{writes: 0}, _, _}
      refute_received {:pass, _, _, _}
    end

    test "the interval timer runs a pass on an idle cache" do
      cache = unique_cache()
      start_supervised!({Theine, name: cache, max_size: :infinity, maintenance_interval: 10})
      attach_pass_handler(cache)

      assert_receive {:pass, _, %{cache: ^cache}, _}, 1_000
      assert_receive {:pass, _, %{cache: ^cache}, _}, 1_000
      assert Maintenance.info(cache).passes >= 2
    end

    test "write_batch applied events trigger a pass, on the send and the call path" do
      cache = unique_cache()

      start_supervised!({Theine, [name: cache, max_size: :infinity, write_batch: 10] ++ @quiet})

      for i <- 1..9, do: Theine.put(cache, i, i)
      assert %{passes: 0, pending: 0} = Maintenance.info(cache)
      Theine.put(cache, 10, 10)
      assert %{passes: 1} = Maintenance.info(cache)

      # Above write_hwm the events arrive as calls (specs/03); they count the
      # same, and the writer is answered before the pass it triggers.
      :atomics.add(Config.get(cache).pending, 1, 10)
      name = Maintenance.name(cache)
      for i <- 11..19, do: :ok = GenServer.call(name, {:event, {:put, i, i, 1, :infinity}})
      assert %{passes: 1} = Maintenance.info(cache)
      assert :ok = GenServer.call(name, {:event, {:put, 20, 20, 1, :infinity}})
      assert %{passes: 2, size: 20, pending: 0} = Maintenance.info(cache)
    end

    test "a put heavier than evict_batch removals is capped and follow-up passes evict the rest" do
      cache = unique_cache()

      # window_percent 80: eighty weight-1 entries in the window, twenty in
      # probation, so a 50-weight entry overflows fifty window entries into
      # probation and the cache is 50 over its bound.
      start_supervised!(
        {Theine,
         [name: cache, max_size: 100, window_percent: 80, evict_batch: 5, write_batch: 1_000] ++
           @quiet}
      )

      for i <- 1..100, do: Theine.put(cache, i, i)

      # One pass to zero the since-last-pass counts; it has nothing to evict.
      Maintenance.run(cache)

      assert %{passes: 1, size: 100, segments: %{window: 80, probation: 20, protected: 0}} =
               Maintenance.info(cache)

      # Five removals as the event is applied (the cap), then :more schedules
      # a :drain; each follow-up pass removes five more and schedules the
      # next until the cache fits: nine passes for the remaining 45.
      attach_pass_handler(cache)
      Theine.put(cache, :big, :big, weight: 50)
      assert_eventually(fn -> Maintenance.info(cache).passes == 10 end)
      info = Maintenance.info(cache)
      assert %{weighted_size: 100, size: 51, passes: 10} = info
      assert info.segments == %{window: 80, probation: 20, protected: 0}
      assert Theine.stats(cache).evictions == 50
      assert {:ok, :big} = Theine.get(cache, :big)
      assert flag(cache) == 0

      # The first pass reports the five evicted as the event was applied
      # plus its own five; the event itself is its one write.
      measurements = passes_received(cache) |> Enum.map(fn {m, _} -> {m.writes, m.evicted} end)
      assert measurements == [{1, 10} | List.duplicate({0, 5}, 8)]
    end

    test "a put that takes the cache over max_size is evicted down before the writer's call returns" do
      cache = unique_cache()
      start_supervised!({Theine, [name: cache, max_size: 10] ++ @quiet})
      %Config{pending: pending, write_hwm: hwm} = Config.get(cache)

      for i <- 1..10, do: Theine.put(cache, i, i)
      assert %{passes: 0, pending: 0, size: 10, call_writes: 0} = Maintenance.info(cache)

      # A pending held at write_hwm makes the next put a backpressure call
      # (specs/03): when it returns, its event has been consumed, and the
      # cache already fits, with no pass having run.
      :atomics.add(pending, 1, hwm)
      assert :ok = Theine.put(cache, 11, 11)
      assert :ets.info(cache, :size) == 10
      assert Theine.stats(cache).evictions == 1

      assert %{passes: 0, pending: ^hwm, size: 10, weighted_size: 10, call_writes: 1} =
               Maintenance.info(cache)

      :atomics.sub(pending, 1, hwm)
    end

    test "the pass's evicted measurement counts the evictions since the previous pass" do
      cache = unique_cache()
      start_supervised!({Theine, [name: cache, max_size: 10, write_batch: 1_000] ++ @quiet})
      attach_pass_handler(cache)

      # Fifteen puts into a bound of ten evict five as they are applied.
      for i <- 1..15, do: Theine.put(cache, i, i)
      assert %{passes: 0, size: 10} = Maintenance.info(cache)
      assert Theine.stats(cache).evictions == 5

      Maintenance.run(cache)
      assert_receive {:pass, %{writes: 15, evicted: 5}, %{cache: ^cache}, _}

      # Nothing since: the count is per pass, like writes.
      Maintenance.run(cache)
      assert_receive {:pass, %{writes: 0, evicted: 0}, %{cache: ^cache}, _}
      refute_received {:pass, _, _, _}
    end

    test "under saturating writers the table never exceeds max_size + pending + writers at any of 200 samples" do
      cache = unique_cache()
      max_size = 10_000
      start_supervised!({Theine, [name: cache, max_size: max_size] ++ @quiet})
      config = Config.get(cache)
      writers = System.schedulers_online()
      stop = :atomics.new(1, [])

      # One writer per scheduler, distinct keys, as mix bench maintenance's
      # write run (specs/09 §`mix bench maintenance`).
      pids = for i <- 1..writers, do: spawn_link(fn -> write_until(cache, stop, i, writers) end)
      refs = Enum.map(pids, &Process.monitor/1)

      # table = policy + pending + in flight: with every :put consumed only
      # once the cache fits (specs/04 §The pass), the policy is at most
      # max_size and the in-flight inserts at most one per writer. The
      # three reads are not simultaneous, so pending is read before and
      # after the table: a sample can only break the bound if pending
      # peaked strictly between the two reads, which the backpressure band
      # (pending within write_hwm..write_hwm + writers) rules out.
      samples =
        for _ <- 1..200 do
          before = :atomics.get(config.pending, 1)
          table = :ets.info(cache, :size)
          after_table = :atomics.get(config.pending, 1)
          Process.sleep(5)
          {table, max(before, after_table)}
        end

      :atomics.put(stop, 1, 1)
      for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, :normal}, 5_000)

      for {table, pending} <- samples do
        assert table <= max_size + pending + writers
        # The spec's own statement of the slack (specs/03 §Delivery with
        # backpressure, A5), from the table reading alone.
        assert table <= max_size + config.write_hwm + writers
      end

      # The writers did push the cache past its bound, and it comes back to
      # it once their events are consumed, with no pass needed.
      assert Enum.any?(samples, fn {table, _} -> table > max_size end)
      assert_eventually(fn -> Maintenance.info(cache).pending == 0 end)
      assert :ets.info(cache, :size) == max_size
      assert Theine.weighted_size(cache) == max_size
    end

    test "a full stripe schedules exactly one follow-up pass" do
      cache = unique_cache()

      start_supervised!(
        {Theine,
         [
           name: cache,
           max_size: 100,
           stripes: 1,
           read_buffer_slots: 4,
           drain_threshold: 8,
           test_hooks: true
         ] ++ @quiet}
      )

      config = Config.get(cache)
      :ok = Maintenance.pause(cache)
      # The eighth read sends the one :drain; the ring of four is lapped.
      for i <- 1..10, do: :ok = ReadBuffer.record(config, i)
      :ok = Maintenance.resume(cache)

      # The reader's :drain ran a pass that found the stripe full (ten
      # sequences claimed against four slots) and scheduled one more; that
      # one, deferred by drain_backoff × the first pass's duration, found it
      # empty and stopped.
      assert_eventually(fn -> Maintenance.info(cache).passes == 2 end)
      Process.sleep(20)
      assert %{passes: 2, read_buffer: %{lag: 0}} = Maintenance.info(cache)
      assert flag(cache) == 0
    end

    test "sketch aging starts at sample_size and a small sketch resets within one pass" do
      cache = unique_cache()
      start_supervised!({Theine, [name: cache, max_size: 8, write_batch: 1_000] ++ @quiet})
      sketch = Config.get(cache).sketch
      sample_size = Sketch.sample_size(8)

      for i <- 1..(sample_size - 1), do: Theine.put(cache, rem(i, 5), i)
      Maintenance.run(cache)
      assert %{sketch: %{words: 8, increments: increments, reset: nil}} = Maintenance.info(cache)
      assert increments == sample_size - 1
      before = Sketch.dump(sketch)

      Theine.put(cache, 0, 0)
      Maintenance.run(cache)
      assert %{sketch: %{increments: after_reset, reset: nil}} = Maintenance.info(cache)
      assert after_reset <= div(sample_size, 2)
      assert Sketch.dump(sketch) != before
    end

    test "a sketch wider than reset_chunk resets one chunk per pass" do
      cache = unique_cache()
      max_size = Sketch.reset_chunk() + 1

      start_supervised!(
        {Theine, [name: cache, max_size: max_size, write_batch: 1_000_000] ++ @quiet}
      )

      words = Sketch.words(max_size)
      assert words == 2 * Sketch.reset_chunk()
      sample_size = Sketch.sample_size(max_size)

      # Overwrites count as accesses, so a working set below max_size keeps
      # eviction out of it.
      for i <- 1..sample_size, do: Theine.put(cache, rem(i, 16_000), i)
      assert %{sketch: %{increments: ^sample_size, reset: nil}} = Maintenance.info(cache)

      Maintenance.run(cache)
      next = Sketch.reset_chunk() + 1

      assert %{sketch: %{increments: ^sample_size, reset: {^next, _odd}}} =
               Maintenance.info(cache)

      Maintenance.run(cache)
      assert %{sketch: %{increments: increments, reset: nil}} = Maintenance.info(cache)
      assert increments <= div(sample_size, 2)

      # clear/1 abandons a reset in progress along with the sketch.
      for i <- 1..sample_size, do: Theine.put(cache, rem(i, 16_000), i)
      Maintenance.run(cache)
      assert %{sketch: %{reset: {^next, _}}} = Maintenance.info(cache)
      Theine.clear(cache)
      assert %{sketch: %{increments: 0, reset: nil}} = Maintenance.info(cache)
    end
  end

  describe "drain backoff (specs/04 §The pass, §Decisions M2.8c)" do
    # One stripe of eight with a threshold of four: the fourth read of the
    # test process sends the one :drain, and the ring holds every read.
    @small [stripes: 1, read_buffer_slots: 8, drain_threshold: 4, test_hooks: true]

    test "drain-triggered passes under a flooding reader keep the pass time under a quarter of wall time" do
      cache = unique_cache()
      start_supervised!({Theine, [name: cache, max_size: 1_000] ++ @quiet})
      for i <- 1..64, do: Theine.put(cache, i, i)
      Maintenance.run(cache)
      attach_pass_handler(cache)

      # One reader saturating its stripe for 300 ms; without the limit the
      # maintenance process was busy 98% of the time behind such a reader
      # (IMPLEMENTATION_PLAN.md, discovered issue 6).
      started = System.monotonic_time()
      deadline = System.monotonic_time(:millisecond) + 300
      reader = spawn_link(fn -> flood(cache, 1, deadline) end)
      ref = Process.monitor(reader)
      assert_receive {:DOWN, ^ref, :process, ^reader, :normal}, 5_000
      # The deferred follow-up of the last trigger, if any, runs inside this.
      Process.sleep(50)
      wall = System.monotonic_time() - started

      durations = for {%{duration: d}, _} <- passes_received(cache), do: d
      assert length(durations) >= 10
      # Every pass but the first follows a gap of at least drain_backoff (3)
      # times the previous pass, so 4 × busy ≤ wall + 3 × the last pass.
      assert Enum.sum(durations) <= div(wall, 4) + Enum.max(durations)
      assert Theine.stats(cache).hits > length(durations) * 64
    end

    test "a deferred drain runs no earlier than drain_backoff × the last pass duration and within a millisecond of it" do
      cache = unique_cache()

      start_supervised!(
        {Theine, [name: cache, max_size: 100, drain_backoff: 1_000] ++ @small ++ @quiet}
      )

      config = Config.get(cache)
      attach_pass_handler(cache)

      # Nothing precedes the first pass, so the reader's :drain runs at once.
      for i <- 1..4, do: :ok = ReadBuffer.record(config, i)
      assert_receive {:pass, %{duration: d1}, %{cache: ^cache}, %{at: end1}}, 1_000
      assert flag(cache) == 0

      # The next :drain arrives within 1_000 × d1 of that pass and waits for
      # the rest of the gap, rounded up to the millisecond.
      for i <- 1..4, do: :ok = ReadBuffer.record(config, i)
      assert_receive {:pass, %{duration: d2, reads: 4}, %{cache: ^cache}, %{at: end2}}, 10_000
      gap = end2 - d2 - end1
      assert gap >= 1_000 * d1
      assert gap <= 1_000 * d1 + ms(1) + ms(200)
      assert flag(cache) == 0
    end

    test "a :drain during the deferral is dropped, the flag stays set, and run/1 is not deferred" do
      cache = unique_cache()

      # A gap of 10_000_000 × the pass duration: seconds at least, so every
      # step below lands inside it.
      start_supervised!(
        {Theine, [name: cache, max_size: 100, drain_backoff: 10_000_000] ++ @small ++ @quiet}
      )

      config = Config.get(cache)
      pid = Process.whereis(Maintenance.name(cache))

      for i <- 1..4, do: :ok = ReadBuffer.record(config, i)
      assert %{passes: 1, read_buffer: %{lag: 0}} = Maintenance.info(cache)
      assert flag(cache) == 0

      # The reader's next :drain is parked; the info call queued behind it
      # finds no second pass and the flag still set.
      for i <- 1..4, do: :ok = ReadBuffer.record(config, i)
      assert %{passes: 1, read_buffer: %{lag: 4}} = Maintenance.info(cache)
      assert flag(cache) == 1

      # A :drain already in flight is dropped rather than parked twice.
      send(Maintenance.name(cache), :drain)
      assert %{passes: 1} = Maintenance.info(cache)

      # Readers past the threshold find the flag set and send nothing.
      for i <- 1..8, do: :ok = ReadBuffer.record(config, i)
      assert Process.info(pid, :message_queue_len) == {:message_queue_len, 0}
      assert %{passes: 1, read_buffer: %{lag: 12}} = Maintenance.info(cache)

      # run/1 passes at once, drains the ring and leaves the flag to the
      # deferred pass.
      assert Maintenance.run(cache) == :ok
      assert %{passes: 2, read_buffer: %{lag: 0}} = Maintenance.info(cache)
      assert flag(cache) == 1
    end

    test "drain_backoff: 0 runs every :drain as it arrives" do
      cache = unique_cache()

      start_supervised!(
        {Theine, [name: cache, max_size: 100, drain_backoff: 0] ++ @small ++ @quiet}
      )

      config = Config.get(cache)

      for i <- 1..4, do: :ok = ReadBuffer.record(config, i)
      assert %{passes: 1} = Maintenance.info(cache)
      for i <- 1..4, do: :ok = ReadBuffer.record(config, i)
      assert %{passes: 2, read_buffer: %{lag: 0}} = Maintenance.info(cache)
      assert flag(cache) == 0
    end
  end

  describe "restart (specs/04 §Restart semantics)" do
    defp children(sup) do
      for {id, pid, _type, _modules} <- Supervisor.which_children(sup), into: %{}, do: {id, pid}
    end

    # Kills the maintenance process of `cache` and returns the pid that
    # replaced it.
    defp restart(cache) do
      old = Process.whereis(Maintenance.name(cache))
      Process.exit(old, :kill)
      assert_eventually(fn -> Process.whereis(Maintenance.name(cache)) not in [nil, old] end)
      Process.whereis(Maintenance.name(cache))
    end

    # Forwards every rebuild event of `cache` as `{:rebuild, measurements,
    # metadata}`; attached before the cache starts when the first start's
    # event is wanted too.
    defp attach_rebuild_handler(cache) do
      handler = {__MODULE__, :rebuild, cache}

      :ok =
        :telemetry.attach(
          handler,
          [:theine, :maintenance, :rebuild],
          &__MODULE__.handle_rebuild/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    def handle_rebuild(_event, measurements, metadata, test),
      do: send(test, {:rebuild, measurements, metadata})

    test "killing Maintenance restarts only Maintenance and every readable entry stays readable" do
      cache = unique_cache()
      start_supervised!({Theine, [name: cache, max_size: 1_000, test_hooks: true] ++ @quiet})
      sup = Process.whereis(Theine.Supervisor.name(cache))
      config = Config.get(cache)
      before = children(sup)

      for i <- 1..50, do: Theine.put(cache, i, i)
      Theine.put(cache, :ttl, 1, ttl: 60_000)
      for _ <- 1..3, do: {:ok, 1} = Theine.get(cache, 1)
      Maintenance.run(cache)
      assert %{passes: 1, size: 51, sketch: %{increments: 54}} = Maintenance.info(cache)
      # Key 1 overflowed into probation as the later puts were applied
      # (eviction runs per applied :put) and the pass's reads promoted it.
      assert {:ok, {1, _, :protected, _, 1, :infinity}} = Maintenance.policy_row(cache, 1)

      # Paused: ten more writes queue as events in the mailbox, and five
      # reads sit in the ring, when the process is killed. The events die
      # with it; the writes are in the table.
      :ok = Maintenance.pause(cache)
      for i <- 51..60, do: Theine.put(cache, i, i)
      for _ <- 1..5, do: :ok = ReadBuffer.record(config, id_of(cache, 1))
      assert :atomics.get(config.pending, 1) == 10
      :atomics.put(config.flags, @drain_flag, 1)

      maintenance = restart(cache)
      assert children(sup) == %{before | Theine.Maintenance => maintenance}
      assert :ets.info(cache, :owner) == before[Theine.Owner]

      # Rebuilt cold: every entry in probation under the table's id, with
      # its stored weight and expiry; nothing pending, no lag, no pass, an
      # empty sketch, the flag clear and the scan's fix released.
      assert %{
               passes: 0,
               pending: 0,
               size: 61,
               weighted_size: 61,
               segments: %{window: 0, probation: 61, protected: 0},
               read_buffer: %{lag: 0},
               sketch: %{increments: 0, reset: nil}
             } = Maintenance.info(cache)

      for i <- 1..60 do
        id = id_of(cache, i)
        assert {:ok, {^i, ^id, :probation, _, 1, :infinity}} = Maintenance.policy_row(cache, i)
      end

      assert {:ok, {:ttl, _, :probation, _, 1, expires_at}} = Maintenance.policy_row(cache, :ttl)
      assert is_integer(expires_at)
      assert Sketch.frequency(config.sketch, 1) == 0
      assert flag(cache) == 0
      assert :ets.info(cache, :safe_fixed_monotonic_time) == false

      for i <- 1..60, do: assert(Theine.get(cache, i) == {:ok, i})
      assert Theine.get(cache, :ttl) == {:ok, 1}
      assert :ets.info(cache, :size) == 61
    end

    test "after a restart with 20_000 entries the policy count equals the table size once idle" do
      cache = unique_cache()
      attach_rebuild_handler(cache)

      start_supervised!(
        {Theine, [name: cache, max_size: 50_000, write_batch: 1_000_000] ++ @quiet}
      )

      # A fresh start scans the empty table: one event, nothing restored.
      assert_receive {:rebuild, %{entries: 0, chunks: 0, duration: d0}, %{cache: ^cache}}, 1_000
      assert is_integer(d0) and d0 >= 0

      for i <- 1..20_000, do: Theine.put(cache, i, i)
      Maintenance.run(cache)
      assert %{size: 20_000, pending: 0} = Maintenance.info(cache)

      restart(cache)

      # Two chunks of rebuild_chunk at least (specs/04 step 3).
      assert_receive {:rebuild, %{entries: 20_000, chunks: chunks}, %{cache: ^cache}}, 5_000
      assert chunks >= div(20_000, Maintenance.rebuild_chunk())

      assert_eventually(fn -> Maintenance.info(cache).pending == 0 end, 5_000)
      assert %{size: 20_000, weighted_size: 20_000, passes: 0} = Maintenance.info(cache)
      assert :ets.info(cache, :size) == 20_000

      for i <- 1..20_000//997 do
        id = id_of(cache, i)
        assert {:ok, {^i, ^id, :probation, _, 1, :infinity}} = Maintenance.policy_row(cache, i)
      end
    end

    test "a put during the rebuild is not lost" do
      cache = unique_cache()

      start_supervised!(
        {Theine,
         [name: cache, max_size: 1_000, test_hooks: true, policy_module: Theine.Test.Policy] ++
           @quiet}
      )

      config = Config.get(cache)
      for i <- 1..50, do: Theine.put(cache, i, i)
      Maintenance.run(cache)

      # The restarted process stops inside its first restore, with the
      # scan under way and its name registered.
      :ok = Theine.Test.Policy.gate(cache, :restore)
      old = Process.whereis(Maintenance.name(cache))
      Process.exit(old, :kill)
      assert_receive {Theine.Test.Policy, ^cache, :gated, :restore, pid}, 5_000
      assert pid != old
      assert Process.whereis(Maintenance.name(cache)) == pid
      assert Theine.size(cache) == 0

      # Writes land in the table at once; their events wait behind the scan.
      :ok = Theine.put(cache, :new, 1)
      :ok = Theine.put(cache, 1, :rewritten)
      :ok = Theine.delete(cache, 2)
      assert :atomics.get(config.pending, 1) == 3
      assert Process.info(pid, :message_queue_len) == {:message_queue_len, 3}
      assert Theine.size(cache) == 0

      :ok = Theine.Test.Policy.release(cache, pid)

      # 50 restored or rewritten, minus the deleted key, plus the new one;
      # every row carries the id the table holds.
      assert %{pending: 0, size: 50, weighted_size: 50} = Maintenance.info(cache)
      new_id = id_of(cache, :new)

      assert {:ok, {:new, ^new_id, :window, _, 1, :infinity}} =
               Maintenance.policy_row(cache, :new)

      id1 = id_of(cache, 1)
      assert {:ok, {1, ^id1, :probation, _, 1, :infinity}} = Maintenance.policy_row(cache, 1)
      assert Maintenance.policy_row(cache, 2) == :error
      assert Theine.get(cache, 1) == {:ok, :rewritten}
      assert Theine.get(cache, :new) == {:ok, 1}
      assert Theine.get(cache, 2) == :error
      assert :ets.info(cache, :size) == 50
    end

    test "writers do not crash when Maintenance is restarting" do
      cache = unique_cache()
      # A low write_hwm keeps writers on the call path too.
      start_supervised!({Theine, [name: cache, max_size: 10_000, write_hwm: 4] ++ @quiet})
      test = self()
      writers = 4

      for w <- 1..writers do
        spawn_link(fn ->
          for i <- 1..2_000 do
            key = {w, rem(i, 100)}
            :ok = Theine.put(cache, key, i)
            if rem(i, 7) == 0, do: :ok = Theine.delete(cache, key)
          end

          send(test, {:writer_done, w})
        end)
      end

      # Three kills, the supervisor's default restart intensity, spread
      # over the writers' run.
      for _ <- 1..3 do
        Process.sleep(5)
        if pid = Process.whereis(Maintenance.name(cache)), do: Process.exit(pid, :kill)
      end

      for w <- 1..writers, do: assert_receive({:writer_done, ^w}, 10_000)
      assert_eventually(fn -> is_pid(Process.whereis(Maintenance.name(cache))) end)
      assert Process.alive?(Process.whereis(Theine.Supervisor.name(cache)))

      # Once idle the policy and the table agree on every key.
      assert_eventually(
        fn ->
          info = Maintenance.info(cache)
          assert info.size == :ets.info(cache, :size)
          assert info.weighted_size == info.size
        end,
        5_000
      )

      for {key, _value, id, _weight, _written_at, _expires_at} <- :ets.tab2list(cache) do
        assert {:ok, {^key, ^id, _, _, 1, :infinity}} = Maintenance.policy_row(cache, key)
      end

      # `pending` can sit below zero by one per writer per restart: an
      # event counted before a restart's reset and consumed after it
      # (specs/04 §Decisions M2.9).
      assert Maintenance.info(cache).pending in -(3 * writers)..0//1
    end

    test "an unbounded cache rebuilds its rows too" do
      cache = unique_cache()
      start_supervised!({Theine, [name: cache, max_size: :infinity, test_hooks: true] ++ @quiet})
      config = Config.get(cache)

      for i <- 1..100, do: Theine.put(cache, i, i, weight: 2)
      :ok = Maintenance.pause(cache)
      for i <- 101..110, do: Theine.put(cache, i, i, weight: 2)
      assert :atomics.get(config.pending, 1) == 10
      restart(cache)

      assert %{
               passes: 0,
               pending: 0,
               size: 110,
               weighted_size: 220,
               segments: nil,
               read_buffer: nil,
               sketch: nil
             } = Maintenance.info(cache)

      for i <- 1..110//13 do
        id = id_of(cache, i)
        assert {:ok, {^i, ^id, nil, _, 2, :infinity}} = Maintenance.policy_row(cache, i)
        assert Theine.get(cache, i) == {:ok, i}
      end

      Theine.delete(cache, 1)
      assert %{size: 109, weighted_size: 218} = Maintenance.info(cache)
      assert :ets.info(cache, :safe_fixed_monotonic_time) == false
    end

    test "a rebuilt cache over max_size schedules a :drain and the pass evicts down to it" do
      cache = unique_cache()

      start_supervised!(
        {Theine, [name: cache, max_size: 100, write_batch: 1_000, test_hooks: true] ++ @quiet}
      )

      # Paused, so the 150 events are in the mailbox when the process dies
      # and the rebuild alone must learn the entries.
      :ok = Maintenance.pause(cache)
      for i <- 1..150, do: Theine.put(cache, i, i)
      attach_pass_handler(cache)
      restart(cache)

      assert_eventually(fn -> Theine.size(cache) == 100 end)
      assert :ets.info(cache, :size) == 100
      assert Theine.weighted_size(cache) == 100
      assert Theine.stats(cache).evictions == 50
      info = Maintenance.info(cache)
      assert info.passes >= 1
      assert info.segments == %{window: 0, probation: 100, protected: 0}
      assert flag(cache) == 0

      # The pass's own step 5 did the evicting here, and its measurement
      # counts them.
      assert passes_received(cache) |> Enum.map(fn {m, _} -> m.evicted end) |> Enum.sum() == 50
    end
  end
end
