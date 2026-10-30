# 07 — Loading from an L2

One topic: `Theine.Loader`, how a miss is turned into a value from a slower
source with exactly one load per key per miss, how callers can await that
asynchronously, and how stale values are refreshed in the background. This
is Caffeine's `LoadingCache`, `AsyncLoadingCache` and `refreshAfterWrite`.

## The loader function

```elixir
@type loader :: (key -> {:commit, value} | {:commit, value, [ttl: ms]} | {:ignore, value})
```

- `{:commit, value}` stores the value (with the cache's default TTL or the
  one given) and returns it to every waiter.
- `{:ignore, value}` returns the value to every waiter and stores nothing.
  Use it for "not found" results that should not occupy the cache.
- Raising, throwing or exiting propagates to the claimant as it would from
  any function call, and every waiter receives `{:error, {:load_failed,
  reason}}`. Nothing is stored. (Caffeine propagates the exception to every
  future; this is the same contract.) The shape of `reason`:
  - raise → the exception struct;
  - throw → `{:nocatch, value}`;
  - exit → the exit reason;
  - claimant died before notifying (waiter saw `:DOWN`) → the monitor's
    reason, e.g. `:killed`.
  `fetch/3`'s `@doc` lists these four.

A loader may be given per call (`fetch/3`) or once for the cache
(`start_link` option `loader:`). A per-call loader wins. `fetch/2` without
either raises `ArgumentError` at call time.

Loaders run in the calling process for `fetch/3` and in a task under the
cache's `Task.Supervisor` for `fetch_async/3` and refreshes. Theine never
calls a loader from the maintenance process.

## Single-flight: `fetch/3`

Two public ETS tables, owned by `Theine.Owner`:

```
inflight :set            {key, claimant_pid, ref}
waiters  :duplicate_bag  {{key, ref}, waiter_pid, monitor_ref}
```

Both with `write_concurrency: :auto`. They are empty whenever no load is in
progress, so their size is bounded by concurrency, not by cache size.

### Algorithm

```
fetch(cache, key, loader, opts):
  case get(cache, key):
    {:ok, v} -> maybe_refresh(cache, key, entry, loader); {:ok, v}
    :error   -> claim_or_wait(cache, key, loader, opts, attempts = 0)
```

**claim_or_wait**:

1. `ref = make_ref()`. If `:ets.insert_new(inflight, {key, self(), ref})`
   succeeds, this process is the **claimant**; go to *Load*, which first
   looks the key up again (a previous claimant may have committed and
   released since this process missed).
2. Otherwise `[{^key, pid, ref}] = :ets.lookup(inflight, key)` (if the
   lookup is empty the claimant already finished: go to step 6).
   `mon = :erlang.monitor(:process, pid, alias: :demonitor)`. Insert
   `{{key, ref}, self(), mon}` into `waiters`.
3. **Double-check**: if `:ets.lookup(inflight, key)` no longer returns that
   exact `{key, pid, ref}`, the claimant finished between steps 1 and 2 and
   may have already notified waiters. Deregister (`:ets.delete_object` the
   waiter row, `Process.demonitor(mon, [:flush])`); if a
   `{:theine_loaded, ^mon, result}` is already in the mailbox return
   `result`, else go to step 6.
4. `receive` one of:
   - `{:theine_loaded, ^mon, result}` → demonitor with flush, return
     `result`.
   - `{:DOWN, ^mon, :process, _, reason}` → the claimant died before
     notifying. Delete the waiter row and the dead claim
     (`:ets.delete_object(inflight, {key, pid, ref})`, so a new claim is
     untouched). If the key is now cached (the claimant committed and then
     died), return it. Else if `reason` is `:normal` or `:noproc`, go to
     step 6 (`:normal`: the claimant finished and this waiter was
     registered too late; the double-check in step 3 makes this rare but
     not impossible when the claimant is a process that exits right after
     returning; `:noproc`: the claimant was already dead when monitored,
     so its claim was stale). Else return `{:error, {:load_failed,
     reason}}`.
   - after `opts[:timeout]` (default 5000 ms) → delete the waiter row,
     demonitor with flush; return a `{:theine_loaded, ^mon, result}`
     already in the mailbox, else `{:error, :timeout}`.
5. (unreachable)
6. **Retry**: `get` again; on hit return it. On miss, if `attempts < 3`,
   go to step 1 with `attempts + 1`; else run the loader in this process
   without claiming (give up on coalescing rather than spin), storing on
   `:commit`.

**Load** (claimant):

```
try
  if the table holds a live entry for key with value v:  # no stats, no read record
    reply = {:ok, v}                                      # committed since our miss
  else
    result = loader.(key)
    case result:
      {:commit, v}       -> put(cache, key, v);         reply = {:ok, v}
      {:commit, v, opts} -> put(cache, key, v, opts);   reply = {:ok, v}
      {:ignore, v}       ->                             reply = {:ok, v}
  reply
after
  :ets.delete_object(inflight, {key, self(), ref})  # 1. release the claim
  for {{^key, ^ref}, pid, mon} <- :ets.lookup(waiters, {key, ref}):  # 2. then read waiters
    send(mon, {:theine_loaded, mon, reply_or_error})  # to the monitor alias
  :ets.delete(waiters, {key, ref})
end
```

The order inside `after` is load-bearing: the claim is released *before* the
waiter list is read. A waiter that sees the claim still present at its
double-check (step 3) therefore registered before the claimant read the
list, and will be notified. A waiter that registered after the read will see
the claim gone at step 3 and fall through to the retry. On a raise, the
`after` block runs with `reply_or_error = {:error, {:load_failed, reason}}`
built in a `rescue`/`catch` that re-raises after notifying.

### Why not a GenServer per key or a central coalescer

A central process would serialize every miss on the cache through one
mailbox; a process per key costs a spawn per miss. The ETS claim costs one
`insert_new` on a miss and nothing on a hit, and waiters pay one monitor and
one receive. This keeps misses as cheap as the loader allows.

## Asynchronous: `fetch_async/3`

```elixir
@spec fetch_async(cache, key, loader | nil, opts) :: Task.t()
```

Returns `Task.Supervisor.async_nolink(sup, fn -> fetch(cache, key, loader, opts) end)`.
The caller awaits it with `Task.await/2` or `Task.yield/2`. Coalescing is
inherited from `fetch/3`: ten `fetch_async` calls for one key spawn ten
tasks but run one loader. The task is unlinked so a loader crash reaches the
caller as a `Task.await` exit or `Task.yield` `{:exit, reason}`, never as a
crash of the caller.

An optimization is allowed but not required: if `get/2` hits, return an
already-completed task (`Task.completed/1`) and spawn nothing.

## Refresh-after-write

`refresh_after_write: ms` on `start_link` (default `:infinity`). On a *hit*
in `fetch/3` or `get/2` where `now - written_at >= ms` and a loader is
available (per-call or cache-level), the reader:

1. `:ets.insert_new(refreshing, {key, now})`, a third `Theine.Owner` table.
   If it fails, a refresh is already running; return the stale value.
2. On success, `Task.Supervisor.start_child(sup, fn -> ... end)` that runs
   the loader, stores on `:commit` (which assigns a new id and `written_at`),
   and in an `after` deletes the `refreshing` row. On `:ignore` or an error
   the old value stays and the row is deleted; the error is logged at
   `:warning` with the key omitted (keys may be sensitive) and emitted as
   `[:theine, :refresh, :exception]` telemetry.
3. Return the stale value immediately. The reader never waits.

`get/2` performs the refresh check only when `refresh_after_write` is set,
so the hot-path budget in specs/01 is unchanged for caches without it; with
it, the cost is one integer comparison on a hit and the `insert_new` only
once per refresh window per key.

`refresh(cache, key)` forces the same background refresh regardless of age,
returning `:ok` if started or `{:error, :refreshing}` if one is running.

A refresh for a key that was deleted or evicted during the load still stores
the loaded value (Caffeine stores it too; the value is fresh by definition).

## Acceptance (A4)

- Exactly-once: 1,000 processes call `fetch/3` on one missing key with a
  loader that sleeps 50 ms and increments a counter; the counter ends at 1
  and all 1,000 receive the value. Repeated 100 times in the stress suite
  across random keys and random claimant delays.
- `{:ignore, v}`: all waiters receive `v`; `get/2` afterwards misses.
- Loader raises: the claimant sees the exception; every waiter gets
  `{:error, {:load_failed, _}}`; nothing is cached; `inflight` and
  `waiters` are empty afterwards.
- Claimant killed mid-load (`Process.exit(pid, :kill)`): waiters get
  `{:error, {:load_failed, :killed}}` within the monitor's delivery, and
  the next `fetch` for that key claims successfully (no stale claim).
- Timeout: a waiter with `timeout: 10` and a 100 ms loader returns
  `{:error, :timeout}` and leaves no waiter row.
- `fetch_async`: ten concurrent tasks for one key run the loader once; a
  loader crash surfaces through `Task.yield` as `{:exit, _}`, not as a caller
  crash.
- Refresh: with `refresh_after_write: 20`, a value written at t=0 is served
  as-is at t=25 (no wait, same value), a refresh runs once even under 100
  concurrent readers, and at t=25+load the new value is served. A refresh
  loader that raises leaves the old value and the key refreshable again.
- No leaks: after the stress suite, `inflight`, `waiters` and `refreshing`
  are empty and the task supervisor has no children.

## Decisions

(Add dated entries when the implementation forces a change.)

- 2026-10-29 (M4.1): a killed claimant must not block its key. Its `after`
  never runs, so its claim stays in `inflight`; with the algorithm as
  first written, the next fetcher would monitor the dead pid, receive
  `:DOWN` with `:noproc`, and return `{:error, {:load_failed, :noproc}}`
  on every later miss, which contradicts §Acceptance ("the next `fetch`
  for that key claims successfully"). Step 4 now deletes the dead claim by
  exact object on any `:DOWN` and treats `:noproc` like `:normal` (go to
  step 6), so the first fetcher after the death reclaims the key. Waiters
  registered before the death still get the monitor's reason, as
  §The loader function says.
- 2026-10-29 (M4.1): waiters monitor with `alias: :demonitor` and the
  claimant sends to the monitor alias rather than the waiter pid. A
  waiter that times out demonitors, which deactivates the alias, so a
  notification sent afterwards is dropped by the runtime instead of
  landing in the mailbox of a long-lived caller (a GenServer would see an
  unexpected message). A notification that arrived before the demonitor
  is taken from the mailbox and returned rather than discarded; the same
  applies when the double-check of step 3 fails, since the claimant may
  have read the waiter row after its insert. The claimant releases with
  `:ets.delete_object` on its own claim rather than `:ets.delete` by key,
  which is the same cost and cannot remove another claim.
- 2026-10-29 (M4.1): details §The loader function left open. A waiter's
  `reason` for a raise is `Exception.normalize/3` of what was raised, so
  an Erlang error such as `:badarg` arrives as `%ArgumentError{}`, while
  the claimant re-raises the raw reason with its stacktrace, as from any
  call. A loader result outside the three shapes raises `ArgumentError`
  in the claimant and fails the waiters with it. `{:commit, v, opts}`
  takes the options of `put/4` (`ttl:` and `weight:`), not `ttl:` only.
  `fetch/4` rejects unknown options and a `timeout:` that is not a
  non-negative integer or `:infinity` with `ArgumentError`, and
  `fetch/2` raises for a missing loader even on a hit. `loads` counts
  every completed loader call and `load_failures` the failed ones (as
  Caffeine's `loadCount` and `loadFailureCount`); `{:ignore, v}` is a
  successful load, and an uncoalesced load after step 6 counts and emits
  telemetry like a claimant's.
- 2026-10-29 (M4.1): the two table names are `%Theine.Config{}` fields
  (`inflight`, `waiters`, derived from the cache name like `maintenance`)
  so that a miss does not build atoms. That takes the config map from 33
  to 35 keys; a compiled probe of the `get/2` hit
  (`bench/results/config-keys-m41.exs`, `+S 2`) measured 262/326 ns
  (unbounded/bounded) before and 256/311 ns after, the same within the
  probe's wander. The config was already past the 32-key flatmap limit.
- 2026-10-29 (M4.2): the claimant looks the key up again before it loads.
  As first written, step 1 broke exactly-once: a fetcher whose `get`
  missed while another claimant was loading, and whose `insert_new` ran
  after that claimant had committed and released, won a fresh claim and
  ran the loader a second time. Caffeine's `compute` cannot do this,
  because the map bin is locked across the check and the load. The
  window is a few calls wide and needs the fetcher to be descheduled
  inside it: 300 rounds of 500 racing fetchers never hit it. The paused
  interleaving below hits it every time. The recheck is
  `Theine.Entry.peek/2`, one `:ets.lookup` with no stats, no read-buffer
  record and no expired delete, so the fetch counts one miss, as a waiter
  does. On a live value the claimant releases with `{:ok, v}` (waiters
  that registered on its claim receive it) and loads nothing: no
  telemetry, no `loads`. A value the previous claimant returned with
  `{:ignore, v}` is not in the table, so it is loaded again, as it would
  be on any later miss.
- 2026-10-29 (M4.2): the waiter edge cases are tested at fixed
  interleavings, not by racing. `Theine.Loader` calls a `pause(point,
  key)` macro between the steps (`:claim` before the `insert_new`,
  `:claim_lost` before step 2's lookup, `:monitored` and `:registered`
  around the waiter-row insert, `:timed_out` before the timed-out
  waiter's cleanup). The test build sets `config :theine, loader_hook:
  Theine.Test.LoaderHook`, which stops a fetcher that armed the point.
  Every other build compiles the macro to `:ok`, chosen once by
  `Application.compile_env/3`, as `Theine.Clock` does for the clock
  (specs/06 §Clock). Without the seam, the step-3 double-check branches,
  step 1's empty lookup and the late notification after a timeout run
  only by chance. M5.2 needs every one of those lines covered.
- 2026-10-29 (M4.3): `fetch_async` is not literally `async_nolink(sup,
  fn -> fetch(...) end)`. The caller resolves the loader, validates the
  options and does the `get/2` itself, as §Asynchronous's optional
  hit shortcut needs anyway. Then, on a miss, the task enters the
  single-flight at step 1 (the claim) instead of calling `fetch/4`. Two
  reasons. A missing loader or a bad `timeout:` raises `ArgumentError` in
  the caller, as `fetch/4` does, rather than as an exit from the task. A
  task that called `fetch/4` would also look the key up a second time, so
  every async miss would count two misses in `stats/1`. Skipping the
  lookup does not weaken exactly-once: a value committed between the
  caller's miss and the task's claim is found by the claimant's recheck
  (M4.2) or by waiting on the live claim. The hit shortcut is taken:
  `Task.completed/1`, nothing spawned.
