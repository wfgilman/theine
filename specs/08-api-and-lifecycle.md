# 08 — Public API, options, supervision, stats and telemetry

One topic: the surface a user sees. Behaviour of each call is specified in
the topic specs this one points at; this file fixes names, types, option
defaults, return conventions and the process tree.

## Starting a cache

```elixir
children = [
  {Theine, name: :sessions, max_size: 100_000, expire_after_write: :timer.minutes(10)}
]
```

`Theine.start_link/1` and `Theine.child_spec/1` take a keyword list:

| option | type | default | spec |
|---|---|---|---|
| `name` | atom | required | 01 |
| `max_size` | pos_integer or `:infinity` | required | 05 |
| `weigher` | `(key, value -> pos_integer)` or nil | nil (weight 1) | 01, 05 |
| `expire_after_write` | ms or `:infinity` | `:infinity` | 06 |
| `refresh_after_write` | ms or `:infinity` | `:infinity` | 07 |
| `loader` | loader fun or nil | nil | 07 |
| `window_percent` | 1..80 | 1 | 05 |
| `adaptive` | boolean | true | 05 |
| `stripes` | power of two | schedulers_online rounded up to a power of two | 03 |
| `read_buffer_slots` | power of two | 64 | 03 |
| `drain_threshold` | power of two | 32 | 03 |
| `write_hwm` | pos_integer | 1024 | 03 |
| `write_batch` | pos_integer | 256 | 04 |
| `expire_batch` | pos_integer | 1024 | 04, 06 |
| `evict_batch` | pos_integer | 1024 | 04, 05 |
| `maintenance_interval` | ms | 1000 | 04 |
| `drain_backoff` | non_neg_integer | 3 | 04 (a drain-triggered pass waits this multiple of the last pass's duration; 0 disables) |
| `stats` | boolean | true | this file |
| `test_hooks` | boolean | false | 04 (`pause/1`, `resume/1`; tests only) |
| `policy_module` | module | `Theine.Policy` | 04, 10 (needs `test_hooks: true`; tests only) |

Unknown options raise `ArgumentError` with the option name. `max_size:
:infinity` disables the policy entirely: no sketch, no read buffer, no
`order` table, no eviction; expiration and loading still work. The
maintenance process still keeps the `policy` and `ids` tables for every key
(specs/05 §State), because `size/1` must not use `:ets.info/2` and the
expiry index needs each key's previous `expires_at`. M1 shipped with only
`:infinity` supported; a finite `max_size` is accepted from M2.4, which
allocates the sketch and the read buffer in `Theine.Owner`.

## Calls

All take the cache `name` as first argument. `key` and `value` are any term.

| call | returns | spec |
|---|---|---|
| `get(cache, key)` | `{:ok, value} \| :error` | 01 |
| `get(cache, key, default)` | `value \| default` | 01 |
| `fetch(cache, key)` | `{:ok, value} \| {:error, reason}` using the cache loader | 07 |
| `fetch(cache, key, loader, opts \\ [])` | same, per-call loader; `opts`: `timeout:` | 07 |
| `fetch_async(cache, key, loader \\ nil, opts \\ [])` | `Task.t()` | 07 |
| `put(cache, key, value, opts \\ [])` | `:ok`; `opts`: `ttl:`, `weight:` | 01 |
| `put_new(cache, key, value, opts \\ [])` | `:ok \| {:error, :exists}` | 01 |
| `delete(cache, key)` | `:ok` (idempotent) | 01 |
| `clear(cache)` | `:ok` | 01, 04 |
| `expire(cache, key, ms)` | `boolean` | 06 |
| `persist(cache, key)` | `boolean` | 06 |
| `ttl(cache, key)` | `{:ok, ms \| :infinity} \| :error` | 06 |
| `refresh(cache, key)` | `:ok \| {:error, :refreshing \| :no_loader}` | 07 |
| `size(cache)` | non_neg_integer, entry count as last seen by maintenance | this file |
| `weighted_size(cache)` | non_neg_integer | this file |
| `stats(cache)` | `%Theine.Stats{}` | this file |
| `run_maintenance(cache)` | `:ok` after one full pass (tests, benches) | 04 |

`weight:` on `put` overrides the weigher for that entry. `size/1` reads an
atomics counter maintained by the maintenance process, never
`:ets.info(_, :size)`, which is slow with decentralized counters.

Return conventions: `{:ok, v} | :error` mirrors `Map.fetch/2`; `{:error,
reason}` only where a reason exists (loads). No bang variants in v1.

## Supervision tree

```
Theine.Supervisor (rest_for_one, one per cache, registered as {Theine.Supervisor, name})
├── Theine.Owner        creates entries/inflight/waiters/refreshing tables, atomics (ids,
│                       pending, flags, read buffer, sketch, counters); writes %Config{}
│                       to persistent_term; then only holds them. Never crashes: it does
│                       nothing after init.
├── Task.Supervisor     registered as {Theine.TaskSupervisor, name}; async loads, refreshes
└── Theine.Maintenance  registered as {Theine.Maintenance, name}; rebuilds on restart (04)
```

`rest_for_one` so that an Owner crash (which loses the tables) restarts
everything after it, while a Maintenance crash restarts only Maintenance.
Config holds the maintenance *registered name*, not the pid, so a restart
needs no persistent_term write. Stopping the supervisor deletes the
persistent_term entry in Owner's `terminate/2`.

The first writes of the persistent_term happen once per cache start; a
system with many short-lived caches (tests) will trigger the global GC the
docs warn about. Accept it; document it in the module doc.

## Stats

`:counters` with `write_concurrency`, one per cache, fields: `hits`,
`misses`, `loads`, `load_failures`, `evictions`, `expirations`,
`refreshes`. `stats/1` reads them into `%Theine.Stats{}` with a computed
`hit_rate` (float, 0.0 when no requests).

`hits` is special. In a bounded cache the `hits` counter is never
incremented; `stats/1` reports `hits` as the sum of the read-buffer stripe
tails (specs/03 §Hits from the tails), so a bounded hit does no counters
op at all. In an unbounded cache there is no read buffer and a hit
increments the `hits` counter. The miss path, the expired-read branch and
the loader always use the counters; they are not on the hit budget.

`stats: false` is a boolean on `%Config{}`; `get/2` branches on it once (a
single pattern match, no function-call indirection) to skip the counter op
on an unbounded hit and on a miss. It does not change the bounded hit path,
which has no counter op to skip; the read buffer still claims a sequence
because the policy needs it. The bench reports both modes and the tracing
test asserts the counters-free multiset for the unbounded hit.

## Telemetry

Emitted off the hot path only:

- `[:theine, :maintenance, :pass]` per pass (specs/04).
- `[:theine, :maintenance, :rebuild]` once per maintenance start, with the
  restart rebuild's `duration`, `entries` and `chunks` (specs/04 §Restart
  semantics, §Decisions M2.9).
- `[:theine, :load, :start | :stop | :exception]` around a loader call made
  by a claimant or a refresh task, with `%{cache: name}` metadata and the
  key omitted.
- `[:theine, :refresh, :exception]` (specs/07).
- `[:theine, :eviction]` is **not** emitted per entry in v1 (would be a
  per-eviction cost in the maintenance budget); M6 may add an opt-in
  listener.

## Documentation

Every public function has `@doc` with an example, every option is in the
`start_link/1` doc, and `mix docs` runs without warnings. The README carries
the Caffeine mapping table from specs/00 and the benchmark summary from
specs/09.

## Acceptance

- Starting two caches with different names works; starting the same name
  twice returns `{:error, {:already_started, pid}}`.
- Every call in the table above has a doctest or unit test for its return
  shape, including the error shapes.
- Unknown option raises with the option name in the message.
- `max_size: :infinity` runs with no read-buffer or sketch allocation
  (`info/1` shows them absent) and `get/2` performs no atomics ops (tracing
  test from specs/01 with the policy-disabled multiset).
- Killing Owner restarts Owner, TaskSupervisor and Maintenance in that order
  and the cache is usable (empty) afterwards. Killing Maintenance restarts
  only Maintenance (specs/04 restart test).
- Stopping the cache removes its persistent_term, its named tables and its
  registered names.
- `stats/1` counts match a scripted sequence of hits, misses, loads,
  evictions and expirations exactly.

## Decisions

- 2026-10-27 (M1.1): registered names are atoms built from the module and
  the cache name (`Theine.Maintenance.sessions`, via `Module.concat/2`),
  not `{Module, name}` tuples. `send/2` on the write path (specs/03) and
  the "unregistered name raises `ArgumentError`" behaviour it relies on
  need a local atom name; a tuple would require a Registry and a `via`
  lookup per write. Cache names are atoms already, so no new atoms are
  created beyond one per registered process. The tree diagram above keeps
  the `{Module, name}` notation to mean "the name derived from both".
- 2026-10-27 (M1.1): a restarted `Theine.Owner` keeps the atomics and
  counters already in `persistent_term` when the options are unchanged,
  recreating only the entries table, so the term is written once per
  cache lifetime even across Owner restarts (no extra global GC, ids stay
  monotonic, stats survive). If the stored options differ (a brutal kill
  of the whole tree followed by a start with new options) it allocates and
  writes afresh.
- 2026-10-27 (M1.1): `Theine.start_link/1` and `child_spec/1` validate
  the options in the caller, so `ArgumentError` is raised there rather
  than surfacing as a supervisor start error.
- 2026-10-27 (after M1.2, human decision): `hits` for a bounded cache comes from
  the read-buffer tails and the bounded hit path performs no `:counters`
  op (specs/01, 03). `stats: false` therefore only affects unbounded hits
  and the miss path. The A1/A2 thresholds were reset at the same time
  (specs/00, 09 §Decisions).
- 2026-10-27 (M1.6): `stats: false` turns off the *request* counters only.
  `hits` and `misses` are never incremented by `get/2`, including the miss
  an expired read would count, so `stats/1` reports both as 0 and
  `hit_rate` as 0.0. The *event* counters (`expirations`, `evictions`,
  `loads`, `load_failures`, `refreshes`) are maintained regardless of the
  option: every site that increments them is off the hot path, so the
  option saves nothing there, and operators still get to see what the
  cache did. §Stats above was silent on the expired-read branch and the
  other sites; the rule "request counters off, event counters on" is the
  one `Theine.Stats` documents. `Theine.Stats` fixes the counter indices
  (`hits/0` … `refreshes/0`); the hot path reads them as compile-time
  constants. The "single pattern match" in §Stats is on one map key, not
  two: `Theine.Owner` stores the counters ref a second time as the runtime
  field `request_counters`, nil under `stats: false`, and `get/2` matches
  `%{request_counters: nil}` or `%{request_counters: c}`. Matching
  `%{stats: true, counters: c}` instead costs a second map fetch on every
  hit, visible as a few ns in the first M1.6 `mix bench get` run.
- 2026-10-28 (M2.7): `policy_module` is the "test-only config field" of
  specs/10 §Required helpers, surfaced as a `start_link` option so the
  test suite can set it without a second `:persistent_term` write. It is
  refused without `test_hooks: true` (`ArgumentError` naming it), which
  keeps the table above honest about what production may set. The
  maintenance process dispatches its policy calls through the field
  (specs/04 §Decisions M2.7); nothing on the read or write path reads it.
- 2026-10-28 (M2.8): a bounded cache started with `stats: false` reports
  `hits` as 0, not as the tail sum. §Stats says the option does not change
  the bounded hit path, and it does not: every hit still claims its
  sequence because the policy needs the read, and `Theine.ReadBuffer.hits/1`
  still returns the true count. But `misses` are not counted under the
  option, so reporting the tails would give a `hit_rate` of 1.0 for a
  cache that was asked not to keep request statistics. `Theine.Stats.hits/1`
  therefore returns 0 when `request_counters` is nil, bounded or not, and
  the documented contract ("`hits` and `misses` read 0, `hit_rate` 0.0",
  M1.6 above) holds in both modes. The hit path reads one config key,
  the runtime field `hit`: `{buffer, stripes - 1, 2 + slots, slots - 1,
  drain_threshold - 1}` in a bounded cache (the masks and stripe width of
  specs/03 §Decisions M2.8b; M2.8 stored the plain sizes), else the
  `request_counters` value. A first version
  matched five keys in one pattern; measured in a compiled loop, that
  five-key `get_map_elements` cost about 8 ns more than a one-key match
  on the 31-key config flatmap and the full `mix bench get` showed the
  unbounded hit about 30 ns slower than in M2.3. Tuple element access is
  a few ns, so the bounded branch destructures the tuple instead.
- 2026-10-29 (M2.9): the `[:theine, :maintenance, :rebuild]` event is
  added to §Telemetry. A maintenance restart is the one lifecycle event
  the cache survives without telling anyone (the supervisor logs the
  crash, nothing reports the recovery), and its cost scales with the
  table, so the rebuild emits one event with its scan duration, entry
  count and chunk count. It is emitted on every maintenance start,
  including the first, so a handler sees one event per start rather than
  having to tell a restart from a start. Off the hot path, as §Telemetry
  requires.
- 2026-10-29 (after M2.10, human decision): `adaptive` defaults to true, as in
  Caffeine; `adaptive: false` is the fixed-window policy (specs/05
  §Adaptive window, specs/00 §Decisions).
