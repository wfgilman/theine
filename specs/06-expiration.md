# 06 — Expiration

One topic: time-based expiry of entries. v1 supports expire-after-write, as a
cache-wide default and as a per-entry TTL, with lazy enforcement on read
(specs/01) and proactive removal by the maintenance process. Refresh-after-
write is a loading concern and lives in specs/07.

## Semantics

- `expire_after_write: ms | :infinity` on `start_link` sets the default
  `expires_at = written_at + ms` for every write. Default `:infinity`.
- `ttl: ms | :infinity` on `put/4`, `put_new/4` and in a loader's `:commit`
  options overrides the default for that entry.
- An entry whose `expires_at <= now` is never returned by `get`, `fetch` or
  any other read. This is enforced on the read path (specs/01 §Expired read)
  and does not depend on the maintenance process being alive or caught up.
- An expired entry is removed from memory by the maintenance sweep within
  `maintenance_interval` ms of expiring, subject to the `expire_batch` cap.
- `expire(cache, key, ms)` sets a new `expires_at = now + ms` for an existing
  key without changing its value or id (an `:ets.update_element/3` on
  position 6, then a `{:put, key, id, weight, expires_at}` event so the index
  updates). Returns `false` if the key is absent.
- `persist(cache, key)` is `expire/3` with `:infinity`.
- `ttl(cache, key)` returns `{:ok, remaining_ms | :infinity}` or `:error`.

Expired entries count as misses in stats and increment the `expirations`
counter when removed by the sweep or by an expired read.

## Index (private ETS, owned by maintenance)

```
expiry :ordered_set  {{expires_at, key}, id}
```

Only entries with an integer `expires_at` are indexed. Maintained from the
write events: `:put` inserts (and deletes the previous `{old_expires_at, key}`
row, which the policy row remembers), `:removed` deletes.

`sweep(now, limit)`: walk from `:ets.first/1` while `expires_at <= now`, at
most `limit` rows; for each, remove the entry from the entries table by
version (specs/04 §Removing an entry) and from the policy. Return the number
removed, so the maintenance pass can decide whether to schedule a follow-up.

This is the ordered-set substitute for Caffeine's hierarchical timer wheel.
It is O(log n) per insert and O(1) amortized per sweep step. If a future
measurement shows the ordered_set as the bottleneck of `put` throughput
(unlikely, since it is off the hot path), a timer wheel can replace it behind
the same `Theine.Expiry` functions.

## Clock

`System.monotonic_time(:millisecond)` everywhere. Tests that need to move
time inject a clock rather than sleeping. The mechanism is
`Application.compile_env(:theine, :clock, nil)`: with `nil` (every
environment but test) the hot path compiles to the direct BIF call; the test
environment sets it to `Theine.Test.Clock`, whose `now/1` takes the cache
name and returns the test clock's time when one is registered for that
cache, else the real clock. The extra Agent round-trip exists only in the
test build, and the tracing test in specs/01 traces only `:ets`,
`:atomics`, `:counters` and `:persistent_term`, so it is unaffected.

## Acceptance

- An entry with a 10 ms TTL is readable at 0 ms and returns `:error` at
  10 ms with the clock advanced and no maintenance pass run (lazy path).
- With the maintenance process paused, expired entries still return `:error`
  and are deleted from the entries table by the reader (specs/01).
- With maintenance running and no reads, an expired entry disappears from
  the entries table within one `maintenance_interval`.
- `expire/3` on a live entry moves it in the index: it is swept at the new
  time, not the old; the old index row is gone.
- `persist/2` removes it from the index entirely.
- Batch cap: 100,000 entries expiring at the same instant are removed over
  several passes, each removing at most `expire_batch`, with follow-up passes
  scheduled without waiting for the interval timer.
- A `put` that races with the sweep of the previous version keeps the new
  value: insert v1 with past expiry, start a sweep, insert v2 concurrently;
  v2 is readable afterwards.
- `mix bench maintenance` with a 50% expiring workload stays under
  `pass_budget`.

## Decisions

- 2026-10-27 (M1.4): the `compile_env` clock is exposed as the macro
  `Theine.Clock.now/1`, required by `Theine` and `Theine.Entry`, rather than
  as a function. specs/01 forbids delegating into another module on the read
  path and the budget has no room for a call, so the call sites expand
  inline: to `:erlang.monotonic_time(:millisecond)` when `:clock` is unset
  (every build but test; verified in the dev build's abstract code, which
  never references the test clock) and to `Theine.Test.Clock.now(cache)` in
  the test build. `put/4` stamps `written_at` through the same macro, keyed
  by `config.name`, so a test clock moves both the write and the read side
  of one cache together. `config/config.exs` imports `config/test.exs` only
  for `config_env() == :test`; a consumer's build never reads either file.
