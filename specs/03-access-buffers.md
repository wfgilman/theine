# 03 — Access buffers: read buffer and write events

One topic: how readers and writers tell the maintenance process what
happened, without locks on the read path and without unbounded growth on the
write path.

## Read buffer: `Theine.ReadBuffer`

Caffeine's `StripedBuffer` of `BoundedBuffer`s: several small ring buffers,
one per stripe, that *drop* an access rather than block or contend when full.
Losing a sampled read is fine; the sketch and the LRUs only need a
representative sample of accesses.

### Layout

One `:atomics` array per cache, unsigned, of size `stripes * (2 + slots)`.
Stripe `s` (0-based) occupies a contiguous region:

```
base      = s * (2 + slots) + 1        # atomics are 1-indexed
base      -> tail   (next sequence number to claim; monotonically increasing)
base + 1  -> head   (next sequence number the drainer will read)
base + 2 .. base + 1 + slots -> ring slots holding ids (0 = empty)
```

Defaults: `stripes = System.schedulers_online()` rounded up to a power of
two, `slots = 64`, `drain_threshold = 32`. All three are `start_link`
options and must be powers of two (`ArgumentError` otherwise), so that
every modulo below is a bit mask; the masks and the stripe width
`2 + slots` are precomputed in the config's `hit` tuple (specs/08).

### `record(config, id)` — the hot-path side

1. `s = :erlang.system_info(:scheduler_id) - 1` modulo `stripes`
   (scheduler ids are 1-based). This is a cheap BIF and gives near-perfect
   striping under normal scheduling. Schedulers beyond the online count
   leave their stripes empty.
2. `t = :atomics.add_get(buf, base, 1) - 1` claims sequence `t`.
3. `:atomics.put(buf, base + 2 + rem(t, slots), id)`, whatever the head
   says. The ring holds the most recent `slots` reads of the stripe; when
   the drainer is more than `slots` behind, the write lands on a slot whose
   read was never drained, and that overwritten read is the **drop**. The
   reader never reads the head.
4. If `rem(t + 1, drain_threshold) == 0`, call `schedule_drain(config)`:
   the flag is tested on every `drain_threshold`-th sequence of the stripe,
   not on every read past a lag.

`schedule_drain/1`: `:atomics.compare_exchange(flags, drain_flag, 0, 1)`;
on `:ok`, `send(config.maintenance, :drain)`. At most one drain message is in
flight per cache; the maintenance process resets the flag to 0 when it
*starts* a drain, so a trigger during the drain schedules the next one. A
trigger that finds the flag set is simply lost; the next test is
`drain_threshold` reads later on that stripe, and the ring keeps the last
`slots` reads whatever happens in between, so `slots` should stay at or
above `2 * drain_threshold` (the defaults are 64 and 32).

Budget on a hit: one scheduler-id read, one add_get, one put, and once per
`drain_threshold` reads one compare_exchange plus one send. That is inside
the "at most three atomics ops" of specs/00 and specs/01 in every case; the
tracing test in specs/01 pins the two-op common hit and the three-op
trigger separately.

`tail` keeps advancing past `head + slots` while the drainer lags, because
every access claims a sequence whether or not its read survives. That is
intended: the drainer reads only the last `slots` sequences, and
`tail - head` is a cheap measure of how far behind maintenance is
(`info/1` reports it).

### Hits from the tails

Because every hit claims a sequence, dropped or not, the sum of the stripe
tails is the exact number of hits recorded since the buffer was created.
`Theine.stats/1` reads `hits` for a bounded cache as that sum, and a bounded
hit performs no `:counters` op (specs/01 §Budget, specs/08 §Stats). The
tails are never reset: a maintenance restart moves heads up to the tails
(specs/04 §Restart semantics), `clear/1` leaves the buffer alone, and only
an Owner restart (which recreates the array) starts the count over, exactly
as it does for the counters. `record/2` must therefore claim the sequence
for every hit, including hits that are dropped and hits in a cache started
with `stats: false`; the one add_get is the whole cost of counting.

Note that a slot may hold a stale id (a reader claimed `t` but has not yet
`put`), a newer id (a reader claimed `t + slots` and wrote it while the
drain was visiting `t`), or 0. The drainer tolerates all three.

### `drain(config, fun)` — the maintenance side

For each stripe: read `head` and `tail`; for each sequence from
`max(head, tail - slots)` to `tail - 1`, read the slot, and if non-zero call
`fun.(id)`; then `put(head, tail_read)`. Readers that claimed a sequence but
have not yet written see their slot drained as 0 or as a previous id; both
are harmless (a lost or duplicated sample). After draining, the drainer does
not zero slots; sequence arithmetic alone decides what is live. A stripe
counts as **full** when `tail - head >= slots` at the time it is read: the
ring reached its capacity since the last drain, so reads may have been
overwritten and the pass follows up (specs/04 §The pass).

The drainer processes at most `stripes * slots` ids per pass, which bounds
pass time.

## Write events: `Theine.WriteEvents`

Writes cannot be lossy: the policy must learn every key that enters the
table, or the cache would hold entries it can never evict. And they must
carry the key, which `:atomics` cannot. So write events are Erlang messages
to the maintenance process, with backpressure so the mailbox stays bounded.

### Events

```
{:put, key, id, weight, expires_at}      a new version of key was inserted
{:removed, key, id}                      key version id was deleted (delete/2 or expired read)
```

### Delivery with backpressure

- `pending` is an `:atomics` counter. The writer does
  `n = :atomics.add_get(pending, 1, 1)`.
- If `n <= write_hwm` (default 1024): `send(maintenance, event)`.
- Else: `GenServer.call(maintenance, {:event, event}, :infinity)`. The call
  returns once the maintenance process has consumed the event. This is
  Caffeine's behaviour of blocking producers on a full write buffer: the
  write still succeeds and is never dropped; the writer just pays the
  maintenance process's lag.
- The maintenance process does `:atomics.sub(pending, 1, 1)` per consumed
  event. It must consume write events in its mailbox before it does policy
  work in a pass, so that backpressure clears quickly (specs/04).

`write_hwm` is also the **write-buffer slack** named in A5: the entries table
may transiently exceed `max_size` by at most `write_hwm` entries' weight plus
the weight of entries currently being inserted.

Every write event is sent *after* the ETS mutation it describes, so the
maintenance process can always find the entry when it processes a `:put`.

`deliver/2` must never crash the writer. During a maintenance restart the
registered name may be absent (`send/2` to an unregistered name raises
`ArgumentError`) or a call in flight may exit when the server dies.
`deliver/2` catches both and returns `:ok`; the lost event is harmless
because the restart rebuild (specs/04) scans the entries table after the
new process registers, and the mutation preceded the send.

## Acceptance

- Property: for any interleaving of `record/2` calls from `k` processes on one
  stripe, `drain/2` yields a sub-multiset of the recorded ids, never an id
  that was not recorded, never more than `slots` ids per pass per stripe.
- `record/2` never blocks and never loops: a stress test with the drainer
  paused shows readers continuing at full speed and `drain/2` later yielding
  at most `slots` ids per stripe ("drops instead of blocking").
- Drain scheduling: with the drainer paused, a flood of reads sends exactly
  one `:drain` message.
- Striping: with one reader process pinned per scheduler (`:erlang.process_flag(:scheduler, n)`
  is not available; use spawn-per-scheduler via `spawn_opt` with
  `{:scheduler, n}`), each stripe receives records.
- Write events are never lost: a stress test performing 1,000,000 `put`s
  across all schedulers ends with the policy's entry count equal to the
  entries table size once maintenance is idle.
- Backpressure: with the maintenance process paused, writers block once
  `pending` exceeds `write_hwm`, and the mailbox never exceeds
  `write_hwm + schedulers` messages.
- A1/A2 unchanged after M2 (the read buffer's cost stays within the budget).

## Decisions

(Add dated entries when the implementation forces a change.)
- 2026-10-27 (after M1.2, human decision): the stripe tails double as the hit
  counter for bounded caches (§Hits from the tails). The tail was already
  incremented on every hit by step 2 of `record/2`; `stats/1` reading
  `stripes` atomics once per call costs nothing on the hot path. This
  removed the `:counters.add` from the bounded hit (specs/01 §Decisions).
- 2026-10-27 (M2.3): the drain is a fold. The maintenance process threads
  its `%Theine.Policy{}` through `Policy.on_access/2`, so `drain/2` with a
  side-effecting `fun.(id)` could not carry the state. `ReadBuffer.drain/3`
  takes `(config, acc, fun.(id, acc))` and returns `{acc, reads, full?}`:
  `reads` is the number of ids handed to `fun` (the `reads` measurement of
  the pass telemetry, specs/04 step 8) and `full?` is true when some stripe
  had `tail - head >= slots` when it was read, the "drained a full stripe"
  condition that makes the pass send itself `:drain`. `drain/2` with a
  one-argument function still exists and returns `{reads, full?}`. The
  layout helpers live in the module that owns the layout: `hits/1` (the
  tail sum, which `Theine.Stats.hits/1` now calls), `lag/1` (the sum of
  `tail - head`, for `info/1`), `reset_heads/1` (for specs/04 §Restart
  semantics step 2) and `dump/1` for tests.
- 2026-10-27 (M2.3): `schedule_drain/1` never raises. `send/2` to an
  unregistered name raises `ArgumentError`, and the maintenance name is
  unregistered while the process restarts, so without a guard a cache hit
  could crash a reader. The send is wrapped in a rescue in the rare branch
  only (the common hit never reaches it), and on failure the flag is left
  set rather than reset: resetting it would make every reader past the
  threshold pay a compare-exchange, a failed send and an exception until the
  restart completes, while leaving it costs them one failed compare-exchange.
  `Theine.Maintenance.init/1` already clears the flag, and the restart
  rebuild schedules its own `:drain` when over capacity (specs/04), so no
  trigger is owed to the reader whose message was lost.
- 2026-10-28 (M2.8b): `record/2` is two atomics ops. The original protocol
  read the head on every hit to refuse a write into a full ring and to
  compare the lag with `drain_threshold`, and called `schedule_drain/1` on
  every read past the threshold. Measured in a compiled loop with the M2.8
  tree, that was about 105 ns over the unbounded hit (each `:atomics` op
  18–25 ns, the `schedule_drain/1` call about 40 ns), against a 65 ns
  budget, and on a full ring every hit paid the compare_exchange, one cache
  line bouncing between all readers at full parallelism; `theine` p50 ran
  at 1.62–1.86× `ets` (IMPLEMENTATION_PLAN.md, discovered issue 6). Now the
  reader always writes slot `rem(t, slots)`, so the ring keeps the most
  recent `slots` reads instead of the first `slots` after a drain, and the
  drain flag is tested on every `drain_threshold`-th sequence
  (`rem(t + 1, drain_threshold) == 0`; `t + 1` so that a fresh stripe's
  first read does not trigger a pass of an empty ring). Nothing on the
  maintenance side changed: the drainer already visited only
  `max(head, tail - slots)..tail - 1`, `full?` is still `tail - head >=
  slots`, and the tails still count every hit. What the policy loses is the
  choice of sample: under a lagging drainer it now sees the newest `slots`
  reads of a stripe rather than the oldest, which is the better sample. A
  trigger lost to a set flag is recovered `drain_threshold` reads later,
  which is why `slots` should be at least `2 * drain_threshold`; a cache
  configured otherwise still works, it just drains a smaller fraction of
  its reads. Measured in the same loop on the same day, the two-op
  protocol with `rem` was still 99 ns over the loop and 77 ns over the
  unbounded hit, because each of the three `rem` operations (stripe, slot,
  trigger) is an integer division; with `stripes`, `slots` and
  `drain_threshold` restricted to powers of two and the masks precomputed
  in the `hit` tuple, the same protocol measures 65 ns, so the three
  options now require powers of two and the default `stripes` is the
  online scheduler count rounded up (Caffeine sizes its buffers the same
  way). Rounding `stripes` up costs the drainer two atomics reads per
  empty stripe per pass and nothing else; rounding the two user-facing
  sizes silently was rejected in favour of an `ArgumentError`, since a
  size the user wrote would otherwise not be the size they got. With this
  protocol the bounded hit measures 53–64 ns over the unbounded one; what
  the bench's p99 still shows at parallel 1 is the pass frequency (the
  `send` on each trigger that finds the flag clear, and the drainer's
  cache traffic on the stripe), which specs/04's drain rate limit
  addresses (IMPLEMENTATION_PLAN.md M2.8c).
