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
    config = %{test: self(), flags: Config.get(cache).flags}

    :ok =
      :telemetry.attach(
        handler,
        [:theine, :maintenance, :pass],
        &__MODULE__.handle_pass/4,
        config
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def handle_pass(_event, measurements, metadata, %{test: test, flags: flags}) do
    at = System.monotonic_time()
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    flag = :atomics.get(flags, @drain_flag)
    send(test, {:pass, measurements, metadata, %{at: at, queue: len, flag: flag}})
  end

  defp ms(n), do: System.convert_time_unit(n, :millisecond, :native)

  # Reads `key` from `cache` as fast as it can until `deadline` (monotonic ms).
  defp flood(cache, key, deadline) do
    {:ok, _} = Theine.get(cache, key)
    if System.monotonic_time(:millisecond) < deadline, do: flood(cache, key, deadline), else: :ok
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
             size: 0,
             weighted_size: 0,
             segments: nil,
             read_buffer: nil,
             sketch: nil
           }

    :atomics.add(Config.get(cache).pending, 1, 3)
    assert Maintenance.info(cache).pending == 3
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
      :ok = Maintenance.pause(cache)
      :atomics.put(config.flags, @drain_flag, 1)
      send(name, :drain)
      for i <- 1..3, do: Theine.put(cache, i, i)
      :ok = ReadBuffer.record(config, id_of(cache, 1))
      :ok = ReadBuffer.record(config, id_of(cache, 2))
      :ok = Maintenance.resume(cache)

      assert %{passes: 1, pending: 0, size: 3} = Maintenance.info(cache)

      assert Theine.Test.Policy.calls(cache) ==
               [:on_write, :on_write, :on_write, :on_access, :on_access, :evict]

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

    test "10_000 queued write events and a full read buffer: one pass consumes at most write_batch * 4 events and stripes * slots reads and schedules a follow-up" do
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

      # The first pass: 1024 of the events in step 1, at most 16 reads in
      # step 3, and, because a stripe was full, the follow-up :drain queued
      # behind the 8_976 events still in the mailbox with the flag set again.
      assert_receive {:pass, measurements, %{cache: ^cache}, %{queue: queue, flag: 1}}, 5_000
      assert measurements.writes == config.write_batch * 4
      assert measurements.reads <= config.stripes * config.read_buffer_slots
      assert measurements.reads > 0
      assert queue == 10_000 - config.write_batch * 4 + 1

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

    test "a capped eviction schedules follow-up passes until the cache fits" do
      cache = unique_cache()

      start_supervised!(
        {Theine, [name: cache, max_size: 100, evict_batch: 5, write_batch: 1_000] ++ @quiet}
      )

      for i <- 1..150, do: Theine.put(cache, i, i)
      assert %{passes: 0, size: 150} = Maintenance.info(cache)

      Maintenance.run(cache)
      assert_eventually(fn -> Theine.size(cache) <= 100 end)
      info = Maintenance.info(cache)
      assert info.size == 100
      assert info.passes >= 10
      assert Theine.stats(cache).evictions == 50
      assert flag(cache) == 0
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
end
