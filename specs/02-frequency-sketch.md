# 02 — Frequency sketch

One topic: `Theine.Sketch`, a count-min sketch with 4-bit counters stored in
an `:atomics` array, used by the policy to estimate how often a key has been
seen. It is Caffeine's `FrequencySketch` with the same layout and the same
aging rule.

## Ownership

The sketch is created by `Theine.Owner` and mutated only by the maintenance
process (specs/04), during drains. There is no concurrent writer, so no
compare-exchange loops are needed: `get/2` then `put/3` on a word is safe.
Keep it that way; if a future spec wants readers to increment the sketch
directly, it must introduce CAS and justify the hot-path cost.

Because `:atomics` arrays live outside any process heap, a sketch for a
million-entry cache (8 MB) costs the maintenance process no GC.

## Layout

- `words = max(8, next_power_of_two(max_size))` 64-bit unsigned words, in
  `:atomics.new(words, signed: false)`. For a weighted cache, `max_size` is
  the maximum weight; cap `words` at `2^30` and document it.
- Each word holds 16 counters of 4 bits (values 0..15).
- Words are grouped in blocks of 8 (64 bytes, one cache line on the JVM; here
  it simply keeps the four reads for one key adjacent).
- `sample_size = 10 * max_size`, `size` is the number of increments since the
  last reset (a plain integer in the maintenance state).

## Hashing

`h = spread(:erlang.phash2(key, 4_294_967_296))`, where `spread/1` is a
32-bit integer mixer (Caffeine uses `h ^= h >>> 17; h *= 0xed5ad4bb;
h ^= h >>> 11; h *= 0xac4c1b51; h ^= h >>> 15`, masked to 32 bits; use that).
Then `block = (h &&& (blocks - 1)) * 8` where `blocks = words / 8`, and for
`i in 0..3`:

```
hi      = (h >>> (i * 8)) &&& 0xFF
index   = block + (hi &&& 7)          # which word in the block
offset  = ((hi >>> 3) &&& 15) * 4     # which nibble
```

Both `index` and `offset` are deterministic functions of `(key, i)`. Write
them once in a private function and test it with fixed vectors so that the
layout never silently changes between commits.

## Operations

- `increment(sketch, key)`: for each of the four counters, if the nibble is
  below 15 add `1 <<< offset` to the word. Then `size + 1`; if
  `size >= sample_size`, call `reset/1`.
- `frequency(sketch, key)`: minimum of the four nibbles. Range 0..15.
- `reset/1`: for every word, `w = (w >>> 1) &&& 0x7777777777777777`, counting
  the nibbles that were odd (`odd`) so that when the reset completes `size`
  becomes `(size - (odd >>> 2)) >>> 1`. Each increment touches four
  counters, so `odd >>> 2` estimates the increments whose halving truncated;
  this is Caffeine's exact rule. Reset is chunked: process
  at most `reset_chunk` words (default 65_536) per maintenance pass and keep a
  cursor in the maintenance state; increments on words past the cursor are
  halved when the cursor reaches them. The sketch is lossy by design, so the
  temporary inconsistency is acceptable; the maintenance pass budget in
  specs/04 is not negotiable.
- `clear/1`: zero every word, `size = 0`. Used by `Theine.clear/1`.

Hot keys saturate at 15 and stop incrementing; the aging halves everything so
that an item seen often last epoch but not this one decays. That is the whole
point: TinyLFU estimates recent popularity, not lifetime popularity.

## Acceptance

- Property: after `n` increments of key `k` with no reset and no other keys,
  `frequency(k) == min(n, 15)`.
- Property (count-min bound): with random keys and no reset,
  `frequency(k) >= true_count(k)` for every `k` (never under-estimates until
  saturation or reset).
- Property: after `reset/1` completes, every nibble is `old >>> 1`, and
  `size` follows the odd-count rule.
- Layout vectors: for a fixed set of keys, `index/offset` pairs match the
  checked-in table in `test/theine/sketch_test.exs`.
- Collision quality: with `max_size = 10_000` and 100_000 distinct keys each
  seen once, at least 95% of keys report `frequency <= 1` (a crude check that
  the hash spread is doing its job).
- Chunked reset: a sketch of 2^20 words resets in passes that each touch at
  most `reset_chunk` words, and `frequency/2` stays within `[old/2, old]` of
  the true halved value for any key throughout.

## Decisions

(Add dated entries when the implementation forces a change.)
