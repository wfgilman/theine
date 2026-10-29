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

The scan yields between chunks (`handle_continue` with the continuation), so
readers and writers are not blocked and write events arriving during the
rebuild are applied after it completes (they are queued in the mailbox).

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
