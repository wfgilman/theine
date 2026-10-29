# 04 — The maintenance process

One topic: `Theine.Maintenance`, the single GenServer per cache that owns the
policy and performs all amortized work. It is Caffeine's
`BoundedLocalCache.maintenance()` plus the `PerformCleanupTask`, as a process.

## Responsibilities

- Own the private ETS tables used by `Theine.Policy` (specs/05) and
  `Theine.Expiry` (specs/06), and the sketch's state (`size`, reset cursor).
- Consume write events and the read buffer.
- Run the maintenance pass in a fixed order, within a time budget.
- Expose `reset/1` (for `clear/1`), `run/1` (force a pass, for tests and
  benches), `pause/1` and `resume/1` (tests only, behind a compile-time flag
  or an opt), and `info/1` (queue depths, last pass duration, counts).

## The pass

Write events are applied as they arrive: `handle_info` (or `handle_call`
for the backpressure path) applies each `{:put,...}`/`{:removed,...}` to the
policy (`Policy.on_write/4`, `Policy.on_remove/2`) and the expiry index,
decrements `pending`, replies if it was a call, and counts it. Nothing
waits for a pass.

A pass is triggered by a `:drain` message (specs/03), by a periodic timer
every `maintenance_interval` ms (default 1000) so expiry runs even on an
idle cache, by `run/1`, or by the count above reaching `write_batch`
(default 256) since the last pass.

Drain-triggered passes are rate limited so that readers cannot keep the
process busy full time: after a pass of duration `d` (whatever triggered
it), a `:drain` that arrives before `drain_backoff × d` (default 3, a
`start_link` option; 0 disables) has elapsed since the pass ended is
deferred with a timer to that moment, rounded up to a whole millisecond,
and the drain flag stays set until the deferred pass starts, so readers
send nothing more in between and a second `:drain` already in flight is
dropped. `run/1`, the interval timer and the `write_batch` trigger are never
deferred. Reads that arrive during the gap beyond the ring's capacity are
dropped, which specs/03 allows: the policy needs a sample, not every read.
A deferred pass runs every step, including the follow-up rule below, so a
cache over capacity still converges.

Order, matching Caffeine:

1. **Flush write events.** Before touching the buffers, receive whatever
   write events are still queued in the mailbox, up to `write_batch * 4`,
   applying them exactly as above. This keeps a pass from acting on a policy
   view that is behind the mailbox and lets backpressure clear quickly.
2. **Clear the drain flag** (`:atomics.put(flags, drain_flag, 0)`), so that
   readers can schedule the next pass while this one runs.
3. **Drain the read buffer** via `ReadBuffer.drain/2`, calling
   `Policy.on_access/2` per id. Stale ids (no longer the key's current
   version, or unknown) are skipped.
4. **Expire** (`Expiry.sweep/2`): remove entries whose `expires_at <= now`,
   up to `expire_batch` (default 1024) per pass.
5. **Evict** (`Policy.evict/1`, called every pass): overflow the window
   into probation, then while the weighted size exceeds `max_size`, run
   W-TinyLFU admission between the window candidate and the probation
   victim, removing the loser from the entries table and the policy.
6. **Sketch aging**: if a reset is in progress, advance it by one chunk.
7. **Adaptive step** (M6 only): `Policy.climb/1` if enabled.
8. Record pass duration and queue depths in the maintenance state and emit
   `[:theine, :maintenance, :pass]` telemetry with measurements
   `%{duration: native, reads: n, writes: n, expired: n, evicted: n}`.

If step 3 drained a full stripe, or step 5 stopped because of the batch cap
while still over capacity, the process sends itself `:drain` so the next pass
follows immediately without waiting for a trigger.

## Budget

One pass must complete in at most `pass_budget` ms of wall time (default 5)
on the reference machine for a `max_size` of 1,000,000, measured by
`mix bench maintenance`. The caps above (`write_batch * 4`, `stripes *
slots`, `expire_batch`, `reset_chunk`, and an eviction cap of
`evict_batch` = 1024 per pass) are what make this hold. Do not remove a cap
to simplify code; raise the cap and re-measure instead.

The maintenance process is the only process that touches the policy tables,
so it never takes a lock and its ETS operations never contend.

## Removing an entry

Eviction and expiry remove from the entries table by exact object
(`:ets.delete_object/2` with the tuple as the policy last saw it: key, id and
the stored fields), never by key. A concurrent `put` that replaced the entry
has a different id, so the fresh value survives and the policy will learn of
it from the `:put` event already in flight. To do this the policy must keep
the fields it needs to reconstruct the tuple, or re-lookup by key and compare
ids before deleting. Re-lookup is simpler and the cost is off the hot path;
prefer it.

Each removal increments the eviction or expiration counter in
`Theine.Stats`.

## Restart semantics

The maintenance process crashing must not lose user data and must not leave
the cache unbounded for long. On `init/1`:

1. Entries table and atomics already exist (owned by `Theine.Owner`).
2. Reset the read buffer heads to their tails, `pending` to 0, the drain flag
   to 0, and clear the sketch.
3. Rebuild policy and expiry tables by scanning the entries table in chunks
   (`:ets.select/3` with a limit, 10_000 per continuation), placing every
   entry in the **probation** segment with its stored `expires_at`. This is
   deliberately a cold policy: with no access history, everything is a
   candidate for eviction, which is the safe default.
4. If the rebuilt weighted size exceeds `max_size`, schedule `:drain`.

The scan runs after `init/1` returns (`handle_continue` with the
continuation, one per chunk), so the supervisor's restart completes and the
registered name is reachable while the table is scanned: readers and writers
are not blocked, and write events arriving during the rebuild queue in the
mailbox and are applied after it completes. The table is fixed
(`:ets.safe_fixtable/2`) for the scan, so a chunked traversal of the `set`
neither skips nor repeats an entry under concurrent writes (§Decisions
M2.9). One `[:theine, :maintenance, :rebuild]` event per maintenance start
reports the scan's `duration`, `entries` and `chunks`.

## Acceptance

- Order: a test with an instrumented policy (test-only module injected via
  config) records the call order within one pass as writes, reads, expire,
  evict.
- Caps: with 10,000 queued write events and a full read buffer, one pass
  consumes at most `write_batch * 4` events and at most `stripes * slots`
  reads, and schedules a follow-up pass.
- Budget: `mix bench maintenance` reports p99 pass duration under
  `pass_budget` at `max_size` 1,000,000 under the mixed workload in specs/09.
- A5: the overshoot test in specs/09 §Bounded passes.
- Restart: kill the maintenance process while the cache holds 100,000
  entries under load; every entry readable before the kill and not expired or
  evicted is still readable after; within two maintenance intervals the
  weighted size is at most `max_size`; no write event is lost (policy count
  equals table size once idle).
- Telemetry: one `[:theine, :maintenance, :pass]` event per pass with the
  measurements listed.

## Decisions

(Add dated entries when the implementation forces a change.)

- 2026-10-27 (M1.3): `pause/1` and `resume/1` are gated by the
  `start_link` option `test_hooks: true` (specs/08 table), not a
  compile-time flag, so the test suite can pause one cache while others in
  the same VM run normally; without it both calls raise `ArgumentError`.
  Paused means the process blocks in a selective receive that matches only
  the `resume/1` call: write events, backpressure calls, `:drain` and the
  interval timer all stay in the mailbox, which is exactly the state a slow
  pass would leave and what the specs/03 backpressure and specs/06 lazy
  expiry tests need to observe. `info/1` and `run/1` therefore also wait
  until `resume/1`; tests inspect `pending` and the mailbox from outside
  (`Process.info/2`) while paused.
- 2026-10-28 (M2.4): `info/1` reports, besides the pass count, last pass
  duration, `pending` and the two sizes, three bounded-only fields that are
  `nil` for `max_size: :infinity`: `segments` (the window, probation and
  protected weights), `read_buffer` (`stripes`, `slots` and the `lag` of
  specs/03) and `sketch` (`words` and the `increments` since the last
  completed reset). That is how specs/08 §Acceptance's "`info/1` shows them
  absent" is observable without reading the config.
- 2026-10-28 (M2.7): the pass as built, where §The pass left room.
  - The instrumented policy of §Acceptance and specs/10 is injected with
    the `start_link` option `policy_module` (default `Theine.Policy`),
    accepted only together with `test_hooks: true` so it stays a test
    hook (specs/08 table). The maintenance process calls `new/1`,
    `on_write/5`, `on_remove/3`, `on_access/2`, `evict/1` and `reset/1`
    through that module; the struct it returns is still `%Theine.Policy{}`,
    read directly for `info/1` and the sketch count. `Theine.Test.Policy`
    forwards every call to `Theine.Policy` and sends its name to a listener
    registered per cache, so the order test reads the call order out of its
    own mailbox.
  - Step 1 receives `{:put, …}`, `{:removed, …}` and `{:"$gen_call", from,
    {:event, …}}` selectively, in their mutual order, and leaves every
    other message in place; the backpressure call is replied to as its
    event is applied, as outside a pass.
  - The `write_batch` trigger counts events applied on arrival since the
    last pass, on the send and the call path alike; it is checked on
    arrival only, never inside step 1, so a flush cannot start a pass
    within a pass. On the call path the writer is answered before the pass
    its event triggers.
  - The follow-up pass after a full stripe or a capped eviction goes
    through `ReadBuffer.schedule_drain/1`, not a bare `send`: step 2 has
    cleared the flag, so the compare-exchange succeeds and one `:drain` is
    queued, unless a reader got there first during the pass, in which case
    that reader's message serves and the "at most one `:drain` in flight"
    rule of specs/03 holds.
  - The `writes` measurement is the number of write events applied since
    the previous pass, on arrival and in step 1, so with the mailbox idle
    before a pass it is exactly what step 1 consumed; `expired` is 0 until
    `Theine.Expiry.sweep/2` lands (M3.1); `duration` is in native units.
    The event's metadata is `%{cache: name}`.
  - Sketch aging (step 6) is the maintenance process's own: it keeps the
    cursor (`nil` or `Theine.Sketch.reset_cursor/0`) in its state, reported
    by `info/1` as `sketch.reset`, starts a reset when the policy's
    `sketch_size` reaches `Sketch.sample_size/1`, advances it by the module
    default chunk once per pass, and applies `Sketch.size_after_reset/2` on
    completion. `reset/1` (`clear/1`) drops a reset in progress with the
    sketch.
  - The periodic trigger is one `Process.send_after/3` timer, re-armed when
    it fires, so the interval is the gap between pass starts.
- 2026-10-28 (M2.8c): drain-triggered passes are rate limited (§The pass).
  Measured with the M2.8b tree under one saturating reader, the process ran
  7_100 passes in 816 ms of wall time (800 ms busy, about 110 µs per pass
  for 64 reads, 1.7 µs per `on_access`): every pass that drained a full
  stripe followed up at once and every reader trigger that found the flag
  clear woke the process, so at full parallelism on the four-scheduler
  reference machine one core went to maintenance and `theine` ips sat at
  0.39–0.52× `ets` (IMPLEMENTATION_PLAN.md, discovered issue 6); at
  parallel 1 the same pass frequency put the bounded p99 at 1.56–2.32×
  `ets` through the `send` on each trigger and the drainer's traffic on the
  reader's stripe. The rule: the pass records `drain_after = finished +
  drain_backoff × duration` after every pass, and a `:drain` arriving
  before it is parked with one `Process.send_after/3` timer for the
  remaining time rounded up to the millisecond (`:deferred_drain`), with
  the flag left set; step 2 skips clearing the flag while such a timer is
  pending, so a `run/1`, timer or `write_batch` pass in the gap leaves the
  deferred pass as the one in flight and the specs/03 "at most one
  `:drain`" rule holds. `drain_after` is set by every pass, not only
  drain-triggered ones, because the cost being limited is the pass itself;
  only the deferral is specific to the drain trigger. With `drain_backoff`
  3 the drain-triggered duty cycle is at most 25% by construction, and in
  practice lower, because BEAM timers are millisecond-grained: a 100 µs
  pass is followed by at least 1 ms of reader-only time, so under a
  saturating reader the process samples the newest `slots` reads of each
  stripe about once per millisecond. The knob is an option rather than a
  constant so that `mix bench get` can try `k` = 7 if 25% is not enough for
  A2 and tests can make the gap wide enough to observe. `drain_backoff: 0`
  restores back-to-back passes. `reset/1` leaves a pending deferral alone;
  it runs a pass on the emptied policy, which is harmless.
- 2026-10-29 (M2.9): the restart rebuild as built, where §Restart semantics
  left room.
  - The scan is `:ets.select/3` with a limit of 10_000
    (`Theine.Maintenance.rebuild_chunk/0`) over a match spec that returns
    `{key, id, weight, expires_at}`, one `handle_continue/2` per chunk,
    with the entries table fixed by `:ets.safe_fixtable/2` from the first
    chunk to the end. The ETS docs guarantee a `select/3` continuation
    traversal of a `set` only while the table is fixed; without the fix a
    concurrent insert that moves a hash bucket could hide an entry from
    the scan, and the policy would never learn it. The fix costs nothing
    on the write path (deleted objects are kept until the release, a few
    milliseconds) and the runtime releases it if the process dies
    mid-scan. The chain of continues handles no message in between, so
    the rebuild is one uninterrupted scan from the mailbox's point of
    view; what the chunking buys is that `init/1` returns at once, the
    supervisor's restart completes and the name is registered before the
    scan starts, so every writer's `send/2` from then on lands in the
    mailbox rather than raising, and `pause/1`-style calls queue rather
    than time out. Writers above `write_hwm` wait in their call for the
    scan to finish, as they would behind a slow pass.
  - Entries are restored through `Theine.Policy.restore/5` (specs/05
    §Events `restore`): probation MRU in scan order, no sketch increment.
    The policy row keeps the stored `expires_at`, so the expiry index of
    specs/06 can be rebuilt from the same call when it lands (M3.1).
  - The scan also runs on a fresh start, over an empty table, so there is
    one code path and one `[:theine, :maintenance, :rebuild]` event per
    maintenance start (measurements `%{duration: native, entries: n,
    chunks: n}`, metadata `%{cache: name}`; specs/08 §Telemetry). The
    event is how a test, or an operator, sees that a restart happened and
    what it cost.
  - Step 4 goes through `ReadBuffer.schedule_drain/1`: the flag was
    cleared in `init/1`, so this queues one `:drain` unless a reader
    already did during the scan, in which case that reader's serves, and
    the "at most one `:drain` in flight" rule of specs/03 holds.
    `drain_after` is nil after a restart, so that pass runs at once.
  - Step 2's reset of `pending` cannot be exact: a writer that counted its
    event before the reset and sent it after (the name is registered
    before `init/1` runs) leaves `pending` one below the true queue depth
    once that event is consumed. The drift is at most one per writer per
    restart, never positive (a send can fail only before the registration,
    hence before the reset that wipes its count), and only delays the
    backpressure threshold by that much; `info/1` may show a small
    negative `pending` after a restart under load. Making it exact would
    need the writer to count after sending, which would cost the hot
    write path a second atomics op, so it is accepted and tested as a
    band.
  - `Theine.Test.Policy` (specs/10) forwards `restore/5` like the other
    calls and gained `gate/2` and `release/2`, which hold the maintenance
    process inside its next call of a given name until the test lets it
    go; that is how "a put during the rebuild is not lost" is tested
    deterministically rather than by racing a 20_000-entry scan.
