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
`:persistent_term` under `{Theine, name}`. It is read on every call and
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

1. `:persistent_term.get({Theine, name})` → config.
2. `:ets.lookup(table, key)`.
3. `[]` → increment the miss counter (one `:counters.add`), return `:error`.
4. `[{^key, value, id, _w, _written, expires_at}]` →
   `now = System.monotonic_time(:millisecond)`;
   if `is_integer(expires_at) and now >= expires_at`, go to *Expired read*.
5. `Theine.ReadBuffer.record(config, id)` (specs/03): one scheduler-id read,
   at most two atomics ops, and at most one more atomics op plus one message
   send when the stripe crosses its drain threshold.
6. Increment the hit counter. Return `{:ok, value}`.

The miss path increments one counter and returns. Misses are not recorded in
the policy; Caffeine does not either.

Budget: steps 1–6 total at most one persistent_term read, one ETS lookup, one
clock read, one scheduler-id read, three atomics ops and one counters op on
the hit path. Logger, telemetry, the process dictionary and any message send
other than the drain trigger are forbidden on this path (AGENTS.md).

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

(Add dated entries when the implementation forces a change.)
