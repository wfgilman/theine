# 01 — Entry store and the read path

One topic: how entries are laid out in ETS and what a read and a write do to
them. Policy is specs/05; expiration is specs/06.

## Tables and handles

Each cache owns one public ETS table, the **entries** table:

```elixir
:ets.new(name, [
  :set, :public, :named_table,
  read_concurrency: true,
  write_concurrency: :auto,
  decentralized_counters: true
])
```

`:named_table` so that `Theine.get(:my_cache, k)` resolves without a
registry lookup. The table is created and owned by `Theine.Owner`, a minimal
process whose only job is to hold ETS tables and atomics so that a maintenance
crash loses no data (specs/08 §Supervision).

Resolved configuration (table name, atomics refs, maintenance pid, stripe
count, TTL defaults, loader) is a `%Theine.Config{}` stored once at startup in
`:persistent_term` under the cache name itself (the bare atom; see
§Decisions 2026-10-27 for why not `{Theine, name}`). It is read on every call and
never rewritten while the cache runs: `clear/1` changes nothing in it, and a
maintenance restart is handled by the new process registering under the same
name, not by storing a pid. `Theine.Owner` writes it once at start and erases
it in `terminate/2`. This is the one sanctioned use of persistent_term:
write-once, read-always.

## Entry layout

```
{key, value, id, weight, written_at, expires_at}
  1    2      3   4       5           6
```

- `id`: integer ≥ 1 from the cache's `:atomics` id counter, `add_get/3`.
  A new id per write. 0 is reserved to mean "empty slot" in the read buffer.
- `weight`: integer ≥ 1 from the weigher (default 1). Entries heavier than
  `max_size` are never admitted (specs/05).
- `written_at`: `System.monotonic_time(:millisecond)` at write.
- `expires_at`: integer monotonic ms, or the atom `:infinity`. Erlang term
  order puts every integer before every atom, so `now >= expires_at` is false
  for `:infinity` without a special case; still, code must guard with
  `is_integer/1` for clarity and Dialyzer.

Values are stored as-is. ETS copies on insert and on lookup; that cost is
the user's value size and is shared with raw ETS, which is why A1 compares
against ETS with identical value shapes.

## Read path: `get/2`

A hit performs exactly these operations, in this order, and nothing else:

1. `:ets.lookup(name, key)`: the entries table is named after the cache, so
   the lookup needs no config.
2. `[]` → `:persistent_term.get(name)` → config; increment the miss counter
   (one `:counters.add`), return `:error`.
3. `[{^key, value, id, _w, _written, expires_at}]` → if
   `is_integer(expires_at)`, read `now = System.monotonic_time(:millisecond)`
   and if `now >= expires_at` go to *Expired read*. Entries with
   `expires_at == :infinity` read no clock.
4. `:persistent_term.get(name)` → config.
5. `Theine.ReadBuffer.record(config, id)` (specs/03): one scheduler-id read,
   at most two atomics ops, and at most one more atomics op plus one message
   send when the stripe crosses its drain threshold.
6. Increment the hit counter. Return `{:ok, value}`.

The miss path increments one counter and returns. Misses are not recorded in
the policy; Caffeine does not either.

Budget: steps 1–6 total at most one persistent_term read, one ETS lookup, one
clock read, one scheduler-id read and three atomics ops on the hit path. A
counters op is allowed on a hit only in an unbounded cache (no read buffer);
in a bounded cache the hit count comes from the read-buffer tails (specs/03
§Hits from the tails) and a hit does no counters op. Logger, telemetry, the process dictionary and any message send
other than the drain trigger are forbidden on this path (AGENTS.md). The
whole path is written out in `Theine.get/2` itself: no delegation into
another module, no struct pattern (one map access for the counters, not a
`__struct__` check plus one), because each of those costs about 10 ns
against a budget of about 60 ns over a raw named-table lookup (§Decisions).

### Expired read

The reader found an entry past its `expires_at`. It:

1. `:ets.delete_object(table, entry)` with the exact tuple it read. A
   concurrent `put` has already replaced the tuple (different id), so this
   never deletes a fresh value. This is the only write a read may perform.
2. Sends the write event `{:removed, key, id}` (specs/03 §Write events).
3. Increments both the miss counter and the expirations counter, and
   returns `:error`.

## Write path: `put/4`

1. Resolve config. Compute `weight` via the weigher if one is configured.
   If `weight > max_size`, do not store; return `:ok` (Caffeine's semantics:
   oversized entries are rejected silently). Document it; test it.
2. `id = :atomics.add_get(config.ids, 1, 1)`.
3. `expires_at` from `ttl:` option, else the cache's `expire_after_write`,
   else `:infinity`. `written_at = now`.
4. `:ets.insert(table, {key, value, id, weight, written_at, expires_at})`.
5. Deliver the write event `{:put, key, id, weight, expires_at}` (specs/03).
   The policy learns the key from this event; the read buffer only ever
   carries ids.

`put_new/4` is the same with `:ets.insert_new/2`; on `false` it returns
`{:error, :exists}` and sends no event.

`delete/2`: `:ets.lookup` to learn the current id (needed so the policy can
discard the right version), `:ets.delete_object` with that exact tuple, then
event `{:removed, key, id}`. If the key is absent, no event. A version
without the lookup (removing "whatever version the policy has") is not
allowed: a `put` racing such a delete could leave an entry in ETS that the
policy has forgotten, which is unbounded until it expires. With the id, the
worst case is the reverse and self-healing: a policy row whose entry is
already gone, dropped at eviction time by the re-lookup in specs/04.

`clear/1`: `:ets.delete_all_objects/1`, then a synchronous
`Theine.Maintenance.reset/1` so that policy tables, sketch and expiry index
are emptied before `clear/1` returns.

## Acceptance

- `get/2` on a hit executes the operation list above and no more. Test by a
  tracing test (`:erlang.trace/3` on `:ets`, `:atomics`, `:counters`,
  `:persistent_term` calls from the calling process) asserting the exact
  multiset of calls for a hit, a miss and an expired read.
- Expired entries are never returned, and an expired read deletes exactly the
  tuple it saw: a put racing with an expired read leaves the new value in
  place (test with a value whose `expires_at` is already in the past when
  inserted).
- Oversized entries are not stored and do not produce a write event.
- `put/4` then `get/2` from a different process returns the value (ETS
  visibility, trivially true; keep the test as a regression guard for table
  options).
- A1 and A2 hold at the end of M1 with policy disabled.

## Decisions

- 2026-10-27 (M1.2): the clock read on both paths is
  `:erlang.monotonic_time(:millisecond)`, the BIF that
  `System.monotonic_time/1` wraps. The wrapper adds a unit-normalising call
  per read, which is measurable against the A1 budget; the values are
  identical. The injected test clock (specs/06 §Clock) replaces this call at
  compile time in the test build only. On a hit the clock is read only when
  the entry has an integer `expires_at`: the result is the same and an
  entry that cannot expire saves the read (about 30 ns).
- 2026-10-27 (M1.2): the persistent_term key is the bare cache name, not
  `{Theine, name}`. Measured on the reference laptop (OTP 28.5, 4
  schedulers): a raw `:ets.lookup/2` on a named table costs about 220 ns,
  so the A1 budget for everything else on a hit is about 65 ns.
  `:persistent_term.get/1` costs 39 ns with a two-tuple key and 16 ns with
  an atom key (the tuple is hashed element by element and allocated per
  call), `:counters.add/3` with `write_concurrency` 30 ns, a remote call
  9 ns, a map field access 5–10 ns, the clock 30 ns. With the tuple key the
  first `mix bench get` run of M1.2 failed 29 of 30 A1/A2 checks at ratios
  of 1.5–2.1; the atom key, the conditional clock and the inlined read
  path bring the unbounded subject under 1.3. The cost of the bare atom is
  a namespace: a cache cannot share its name with a `:persistent_term` key
  another library uses. `Theine.Owner` checks the key at start and raises
  `ArgumentError` if it holds a term that is not a `%Theine.Config{}`, so
  the collision fails loudly rather than overwriting. The same numbers
  mean the bounded hit path of M2.8 (one scheduler-id read and three
  atomics ops more, about 65 ns measured in isolation) will need the same
  care; IMPLEMENTATION_PLAN.md records the risk.
- 2026-10-27 (after M1.2, human decision): a bounded hit does not touch
  `:counters`. The read buffer claims a sequence number on every hit, so
  the sum of the stripe tails is already the exact hit count (specs/03).
  Measured in isolation the counter op is 24 ns of a ~60–100 ns budget over
  a 205 ns lookup; removing it takes the bounded hit from 1.61× to 1.41×
  ETS. The A1/A2 figures themselves were reset at the same time (specs/00
  §Decisions). Unbounded caches have no read buffer and keep the counter
  op on a hit; `stats: false` removes it there.
