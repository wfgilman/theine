defmodule Theine.ReadBufferTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Theine.Test.Helpers

  alias Theine.{Config, Owner, ReadBuffer}

  doctest ReadBuffer

  @drain_flag Owner.drain_flag()

  # A config with a read buffer and flags but no running cache, so the ring
  # protocol is tested on its own (`Theine.get/2` carries a copy of
  # `record/2`; tracing_test pins that copy). `stripes: 1` makes every
  # scheduler record into stripe 0, so single-process tests are
  # deterministic whatever scheduler the test runs on. The maintenance name
  # is unregistered unless the test registers itself under it.
  defp config(opts) do
    stripes = Keyword.get(opts, :stripes, 1)
    slots = Keyword.get(opts, :slots, 8)

    %{
      Config.new!(name: :read_buffer_test, max_size: :infinity)
      | stripes: stripes,
        read_buffer_slots: slots,
        drain_threshold: Keyword.get(opts, :threshold, 4),
        read_buffer: ReadBuffer.new(stripes, slots),
        flags: :atomics.new(1, signed: false),
        maintenance: Keyword.get(opts, :maintenance, unique_maintenance())
    }
  end

  defp unique_maintenance, do: :"read_buffer_maintenance_#{System.unique_integer([:positive])}"

  defp register_as_maintenance do
    name = unique_maintenance()
    Process.register(self(), name)
    name
  end

  defp record_all(config, ids), do: Enum.each(ids, &(:ok = ReadBuffer.record(config, &1)))

  # Drains into a list, oldest first.
  defp drain_list(config) do
    {acc, reads, full?} = ReadBuffer.drain(config, [], &[&1 | &2])
    {Enum.reverse(acc), reads, full?}
  end

  # One reader pinned per scheduler, each recording `ids_for.(scheduler)`;
  # returns once every reader has finished.
  defp record_pinned(config, ids_for) do
    test = self()
    schedulers = System.schedulers_online()

    for n <- 1..schedulers do
      spawn_on_scheduler(n, fn ->
        record_all(config, ids_for.(n))
        send(test, {:done, n})
      end)
    end

    for n <- 1..schedulers, do: assert_receive({:done, ^n}, 10_000)
    schedulers
  end

  defp flag(config), do: :atomics.get(config.flags, @drain_flag)

  describe "layout" do
    test "new/2 allocates stripes * (2 + slots) unsigned words, all zero" do
      buffer = ReadBuffer.new(3, 5)

      assert %{size: 21, min: 0, max: max} = :atomics.info(buffer)
      assert max == Bitwise.bsl(1, 64) - 1
      assert for(i <- 1..21, do: :atomics.get(buffer, i)) == List.duplicate(0, 21)
    end

    test "dump/1 reads each stripe's tail, head and ring in the specs/03 layout" do
      config = config(stripes: 2, slots: 3)
      buffer = config.read_buffer
      # Stripe 1 starts at word 6: tail, head, then three slots.
      :atomics.put(buffer, 6, 9)
      :atomics.put(buffer, 7, 8)
      :atomics.put(buffer, 8, 11)
      :atomics.put(buffer, 10, 13)

      assert ReadBuffer.dump(config) == [
               %{tail: 0, head: 0, ids: [0, 0, 0]},
               %{tail: 9, head: 8, ids: [11, 0, 13]}
             ]
    end

    test "stripe_of/2 is the scheduler id minus one, modulo stripes" do
      assert ReadBuffer.stripe_of(1, 4) == 0
      assert ReadBuffer.stripe_of(4, 4) == 3
      assert ReadBuffer.stripe_of(5, 4) == 0
      assert ReadBuffer.stripe_of(3, 1) == 0
    end
  end

  describe "record/2" do
    test "writes ids into the ring in sequence order and only claims a tail" do
      config = config(slots: 8, threshold: 128)
      record_all(config, 1..5)

      assert ReadBuffer.dump(config) == [%{tail: 5, head: 0, ids: [1, 2, 3, 4, 5, 0, 0, 0]}]
      assert ReadBuffer.hits(config) == 5
      assert ReadBuffer.lag(config) == 5
      assert flag(config) == 0
    end

    test "wraps around the ring while the drainer keeps up" do
      config = config(slots: 8, threshold: 128)
      record_all(config, 1..6)
      assert {Enum.to_list(1..6), 6, false} == drain_list(config)

      record_all(config, 7..12)

      assert ReadBuffer.dump(config) == [%{tail: 12, head: 6, ids: [9, 10, 11, 12, 5, 6, 7, 8]}]
      assert {Enum.to_list(7..12), 6, false} == drain_list(config)
    end

    test "overwrites the oldest undrained reads once the ring is full and keeps claiming sequences" do
      config = config(slots: 4, threshold: 128)
      record_all(config, 1..10)

      # Every sequence was written into slot rem(t, 4) without a look at the
      # head: the ring holds the most recent four reads (sequences 6..9) and
      # the six older ones were overwritten, which is the drop. The tail
      # counts them all the same.
      assert ReadBuffer.dump(config) == [%{tail: 10, head: 0, ids: [9, 10, 7, 8]}]
      assert ReadBuffer.hits(config) == 10
      assert ReadBuffer.lag(config) == 10

      # The drainer visits the last `slots` sequences (6..9) and finds
      # exactly the ids they wrote: never an id that was not recorded, and
      # never more than `slots` of them.
      assert {[7, 8, 9, 10], 4, true} = drain_list(config)
      assert ReadBuffer.lag(config) == 0
      assert ReadBuffer.hits(config) == 10
      assert {[], 0, false} = drain_list(config)
    end

    test "sends exactly one :drain on every drain_threshold-th sequence" do
      name = register_as_maintenance()
      config = config(slots: 8, threshold: 4, maintenance: name)

      record_all(config, 1..3)
      refute_received :drain
      assert flag(config) == 0

      # Sequence 3 is the fourth of the stripe: rem(t + 1, 4) == 0.
      :ok = ReadBuffer.record(config, 4)
      assert_received :drain
      assert flag(config) == 1

      # Sequences 7, 11, ... test the flag again and find it set, so no
      # further trigger reaches the mailbox until the maintenance process
      # clears it at the start of its pass; the reads in between do not
      # test it at all.
      record_all(config, 5..40)
      refute_received :drain

      :atomics.put(config.flags, @drain_flag, 0)
      assert {_, 8, true} = drain_list(config)
      # Sequences 40..42 are not multiples of 4 minus one; 43 is.
      record_all(config, 41..43)
      refute_received :drain
      :ok = ReadBuffer.record(config, 44)
      assert_received :drain
      refute_received :drain
      assert flag(config) == 1
    end

    test "a drain_threshold above slots still triggers every drain_threshold reads and the ring keeps the newest slots" do
      name = register_as_maintenance()
      config = config(slots: 4, threshold: 8, maintenance: name)

      record_all(config, 1..7)
      refute_received :drain
      assert ReadBuffer.dump(config) == [%{tail: 7, head: 0, ids: [5, 6, 7, 4]}]

      :ok = ReadBuffer.record(config, 8)
      assert_received :drain
      assert ReadBuffer.dump(config) == [%{tail: 8, head: 0, ids: [5, 6, 7, 8]}]
      assert {[5, 6, 7, 8], 4, true} = drain_list(config)
    end

    test "a trigger lost to a set flag is retried drain_threshold reads later" do
      name = register_as_maintenance()
      config = config(slots: 8, threshold: 4, maintenance: name)

      # The flag is set by a pass still in flight; the reader at sequence 3
      # pays one failed compare_exchange and sends nothing.
      :atomics.put(config.flags, @drain_flag, 1)
      record_all(config, 1..4)
      refute_received :drain
      assert ReadBuffer.hits(config) == 4

      # The pass clears the flag; sequences 4..6 do not test it, 7 does.
      :atomics.put(config.flags, @drain_flag, 0)
      record_all(config, 5..7)
      refute_received :drain
      :ok = ReadBuffer.record(config, 8)
      assert_received :drain
    end

    test "never raises when the maintenance name is not registered" do
      config = config(slots: 8, threshold: 2)
      refute Process.whereis(config.maintenance)

      record_all(config, 1..20)

      assert flag(config) == 1
      assert ReadBuffer.hits(config) == 20
      assert ReadBuffer.schedule_drain(config) == :ok
    end

    test "the stripe is the scheduler id minus one, modulo stripes" do
      stripes = 2
      per_reader = 3
      config = config(stripes: stripes, slots: 8, threshold: 128)

      schedulers = record_pinned(config, fn n -> for i <- 1..per_reader, do: n * 100 + i end)

      expected_tails =
        for s <- 0..(stripes - 1),
            do: per_reader * Enum.count(1..schedulers, &(ReadBuffer.stripe_of(&1, stripes) == s))

      assert Enum.map(ReadBuffer.dump(config), & &1.tail) == expected_tails
      assert ReadBuffer.hits(config) == per_reader * schedulers
    end

    test "each stripe receives records with one reader pinned per scheduler" do
      # The default stripe count is the scheduler count rounded up to a
      # power of two; stripes past the scheduler count stay empty.
      stripes = Config.default_stripes()
      schedulers = System.schedulers_online()
      slots = 16
      per_reader = 12
      config = config(stripes: stripes, slots: slots, threshold: 128)

      record_pinned(config, fn n -> for i <- 1..per_reader, do: n * 1_000 + i end)

      for {%{tail: tail, head: head, ids: ids}, s} <- Enum.with_index(ReadBuffer.dump(config)) do
        assert head == 0

        if s < schedulers do
          assert tail == per_reader, "stripe #{s} received #{tail} records"
          # Scheduler s + 1 is the only one mapping to stripe s here.
          assert Enum.take(ids, per_reader) == for(i <- 1..per_reader, do: (s + 1) * 1_000 + i)
        else
          assert tail == 0, "stripe #{s} has no scheduler and received #{tail} records"
        end
      end

      assert {_, reads, false} = ReadBuffer.drain(config, [], &[&1 | &2])
      assert reads == schedulers * per_reader
    end
  end

  describe "drain" do
    test "drain/2 calls the function per live id and reports the count and fullness" do
      config = config(slots: 4, threshold: 128)
      record_all(config, [10, 20, 30])
      test = self()

      assert ReadBuffer.drain(config, &send(test, {:id, &1})) == {3, false}
      assert_received {:id, 10}
      assert_received {:id, 20}
      assert_received {:id, 30}
      refute_received {:id, _}

      record_all(config, 31..40)
      assert ReadBuffer.drain(config, &send(test, {:id, &1})) == {4, true}
    end

    test "skips the zero slots of readers that claimed a sequence but have not written" do
      config = config(slots: 4, threshold: 128)
      buffer = config.read_buffer
      # Three sequences claimed, the middle one not yet written.
      :atomics.put(buffer, 1, 3)
      :atomics.put(buffer, 3, 7)
      :atomics.put(buffer, 5, 9)

      assert {[7, 9], 2, false} = drain_list(config)
      assert ReadBuffer.dump(config) == [%{tail: 3, head: 3, ids: [7, 0, 9, 0]}]
    end

    test "drains every stripe in order and moves each head to the tail it read" do
      config = config(stripes: 3, slots: 4, threshold: 128)
      buffer = config.read_buffer

      for {s, ids} <- [{0, [1, 2]}, {1, []}, {2, [3, 4, 5, 6]}] do
        base = s * 6 + 1
        :atomics.put(buffer, base, length(ids))
        for {id, i} <- Enum.with_index(ids), do: :atomics.put(buffer, base + 2 + i, id)
      end

      assert {[1, 2, 3, 4, 5, 6], 6, true} = drain_list(config)
      assert Enum.map(ReadBuffer.dump(config), &{&1.tail, &1.head}) == [{2, 2}, {0, 0}, {4, 4}]
      assert ReadBuffer.lag(config) == 0
    end

    test "reset_heads/1 moves every head to its tail so a drain yields nothing" do
      config = config(stripes: 2, slots: 4, threshold: 128)
      buffer = config.read_buffer
      :atomics.put(buffer, 1, 9)
      :atomics.put(buffer, 3, 5)
      :atomics.put(buffer, 7, 2)
      :atomics.put(buffer, 9, 6)
      assert ReadBuffer.lag(config) == 11

      assert ReadBuffer.reset_heads(config) == :ok

      assert ReadBuffer.lag(config) == 0
      assert ReadBuffer.hits(config) == 11
      assert {[], 0, false} = drain_list(config)
      assert Enum.map(ReadBuffer.dump(config), & &1.head) == [9, 2]
    end
  end

  describe "properties (specs/03 §Acceptance)" do
    property "drain yields a sub-multiset of recorded ids, never more than slots per stripe" do
      check all slots <- member_of([1, 2, 4, 8, 16]),
                lists <- list_of(list_of(positive_integer(), max_length: 40), length: 1..4) do
        config = config(slots: slots, threshold: 1_024)

        lists
        |> Enum.map(fn ids -> Task.async(fn -> record_all(config, ids) end) end)
        |> Task.await_many()

        recorded = List.flatten(lists)
        {drained, reads, full?} = drain_list(config)

        assert reads == length(drained)
        assert reads == min(slots, length(recorded))
        assert full? == length(recorded) >= slots
        assert ReadBuffer.hits(config) == length(recorded)
        assert ReadBuffer.lag(config) == 0

        counts = Enum.frequencies(recorded)

        for {id, n} <- Enum.frequencies(drained) do
          assert n <= Map.get(counts, id, 0), "drained #{id} #{n} times"
        end
      end
    end

    property "ids drained while readers are still recording were all recorded" do
      check all slots <- member_of([1, 2, 4, 8]),
                lists <- list_of(list_of(positive_integer(), max_length: 30), length: 1..3) do
        config = config(slots: slots, threshold: 1_024)
        tasks = Enum.map(lists, fn ids -> Task.async(fn -> record_all(config, ids) end) end)
        recorded = MapSet.new(List.flatten(lists))

        drained = drain_until_done(config, tasks, slots, [])

        assert MapSet.subset?(MapSet.new(drained), recorded)
        assert ReadBuffer.hits(config) == Enum.sum(Enum.map(lists, &length/1))
        assert ReadBuffer.lag(config) == 0
      end
    end

    # Drains repeatedly while the readers run, checks the per-drain cap, and
    # finishes with a drain after the last reader has returned. A task's
    # reply can be yielded only once, so finished tasks leave the list.
    defp drain_until_done(config, [], slots, acc) do
      {ids, reads, _} = drain_list(config)
      assert reads <= slots
      acc ++ ids
    end

    defp drain_until_done(config, tasks, slots, acc) do
      {ids, reads, _} = drain_list(config)
      assert reads <= slots

      pending =
        for {task, result} <- Task.yield_many(tasks, timeout: 0), result == nil, do: task

      drain_until_done(config, pending, slots, acc ++ ids)
    end
  end

  describe "concurrency (specs/03 §Acceptance)" do
    test "drops instead of blocking: readers run with no drainer and a later drain yields at most slots per stripe" do
      stripes = Config.default_stripes()
      schedulers = System.schedulers_online()
      slots = 64
      per_reader = 20_000
      config = config(stripes: stripes, slots: slots, threshold: 32)

      # No process consumes the buffer or the :drain message. Every reader
      # returns regardless; a blocking record would hang the receive below.
      record_pinned(config, fn n -> for i <- 1..per_reader, do: n * 100_000 + i end)

      assert ReadBuffer.hits(config) == schedulers * per_reader
      assert ReadBuffer.lag(config) == schedulers * per_reader

      assert Enum.map(ReadBuffer.dump(config), & &1.tail) ==
               for(s <- 0..(stripes - 1), do: if(s < schedulers, do: per_reader, else: 0))

      {drained, reads, full?} = drain_list(config)

      assert full?
      assert reads <= schedulers * slots
      assert ReadBuffer.lag(config) == 0

      for id <- drained do
        assert rem(id, 100_000) in 1..per_reader and div(id, 100_000) in 1..schedulers,
               "drained #{id}, which no reader recorded"
      end
    end

    test "a flood of reads with the drainer paused sends exactly one :drain message" do
      name = register_as_maintenance()
      stripes = Config.default_stripes()
      config = config(stripes: stripes, slots: 64, threshold: 32, maintenance: name)

      record_pinned(config, fn n -> for i <- 1..5_000, do: n * 10_000 + i end)

      assert_received :drain
      refute_received :drain
      assert flag(config) == 1

      # The pass clears the flag before draining (specs/04 step 2), after
      # which the next crossing sends one more.
      :atomics.put(config.flags, @drain_flag, 0)
      assert {_, reads, true} = ReadBuffer.drain(config, [], &[&1 | &2])
      assert reads <= stripes * 64

      record_pinned(config, fn n -> for i <- 1..5_000, do: n * 10_000 + i end)
      assert_received :drain
      refute_received :drain
    end
  end
end
