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

Defaults: `stripes = System.schedulers_online()`, `slots = 64`,
`drain_threshold = 32`. All three are `start_link` options.

### `record(config, id)` — the hot-path side

1. `s = :erlang.system_info(:scheduler_id) - 1` modulo `stripes`
   (scheduler ids are 1-based). This is a cheap BIF and gives near-perfect
   striping under normal scheduling.
2. `t = :atomics.add_get(buf, base, 1) - 1` claims sequence `t`.
3. `head = :atomics.get(buf, base + 1)`. If `t - head >= slots`, the ring
   is full: **drop** the access (the claimed sequence is simply never
   written) and go to step 5 with `full = true`.
4. `:atomics.put(buf, base + 2 + rem(t, slots), id)`.
5. If `full` or `t - head >= drain_threshold`, call `schedule_drain(config)`.

`schedule_drain/1`: `:atomics.compare_exchange(flags, drain_flag, 0, 1)`;
on `:ok`, `send(config.maintenance, :drain)`. At most one drain message is in
flight per cache; the maintenance process resets the flag to 0 when it
*starts* a drain, so a trigger during the drain schedules the next one.

Budget on a hit: one scheduler-id read, one add_get, one get, one put, and
rarely one compare_exchange plus one send. That is exactly the "at most
three atomics ops" in specs/00 and specs/01 in the common case; the drain
trigger adds a fourth op and a send once per `drain_threshold` reads, and
the tracing test in specs/01 must account for that amortized case
separately.

When the ring is full, `tail` keeps advancing past `head + slots` because
every dropped access still claims a sequence. That is intended: the drainer
reads only the last `slots` sequences, and `tail - head` is a cheap measure
of how far behind maintenance is (`info/1` reports it).

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
`put`), or 0. The drainer tolerates both.

### `drain(config, fun)` — the maintenance side

For each stripe: read `head` and `tail`; for each sequence from
`max(head, tail - slots)` to `tail - 1`, read the slot, and if non-zero call
`fun.(id)`; then `put(head, tail_read)`. Readers that claimed a sequence but
have not yet written see their slot drained as 0 or as a previous id; both
are harmless (a lost or duplicated sample). After draining, the drainer does
not zero slots; sequence arithmetic alone decides what is live.

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
