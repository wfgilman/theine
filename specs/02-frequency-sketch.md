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
`h` picks the block: `block = (h &&& (blocks - 1)) * 8` where
`blocks = words / 8`. A second mixer picks the counters, so that the bits
that chose the block do not also choose a counter:
`c = rehash(h)` with `c = h * 0x31848bab; c ^= c >>> 14`, masked to 32 bits
(Caffeine's `rehash`). Then for `i in 0..3`:

```
ci      = c >>> (i * 8)
index   = block + 2 * i + (ci &&& 1)  # one of the block's i-th word pair
offset  = ((ci >>> 1) &&& 15) * 4     # which nibble
```

A key's four counters are therefore in four distinct words of one block.
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
  at most `reset_chunk` words (default 16_384, see §Decisions M2.2) per
  maintenance pass and keep a cursor in the maintenance state; increments on
  words past the cursor are halved when the cursor reaches them. The sketch is lossy by design, so the
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
  seen once and no reset, at least 99% of keys report `frequency <= 3` and
  at least 55% report `frequency <= 1` (a crude check that the hash spread
  is doing its job; see §Decisions for where the figures come from).
- Chunked reset: a sketch of 2^20 words resets in passes that each touch at
  most `reset_chunk` words, and `frequency/2` stays within `[old/2, old]` of
  the true halved value for any key throughout.

## Decisions

(Add dated entries when the implementation forces a change.)

- 2026-10-27 (M2.1): the counter layout is Caffeine's actual block layout
  (`rehash`, word pairs), not the earlier paraphrase
  `index = block + (hi &&& 7)`, `offset = ((hi >>> 3) &&& 15) * 4` with
  `hi` taken from the same `h` that chose the block. That paraphrase reused
  the block's bits for counter 0: with `max_size` 10_000 (2_048 blocks, 11
  block bits) counter 0's byte was fully determined by the block, so every
  key in a block shared one nibble, and counter 1's word was fixed per
  block as well. The sketch was effectively two or three hashes, and it
  could place two of a key's counters in the same nibble, which breaks the
  `frequency == min(n, 15)` property. Measured with 100_000 single-hit keys
  at `max_size` 10_000: `frequency <= 3` for 99.7% of keys under the block
  layout against 98.4% under the paraphrase, and `<= 4` for 99.99% against
  99.5%.
- 2026-10-27 (M2.1): the collision-quality threshold was "95% report
  `frequency <= 1`" for 100_000 single-hit keys at `max_size` 10_000. That
  cannot hold for any hash: the sketch has 16_384 words, 262_144 nibbles,
  and takes 400_000 increments, a mean load of 1.53 per nibble, so a key's
  counter is free of other keys with probability e^-1.53 ≈ 0.22 and
  `min(4 counters) <= 1` with probability 1 - 0.78^4 ≈ 0.62. Measured:
  61–65% under both layouts. The acceptance now asks for 99% at `<= 3`
  (model 99.85%, measured 99.7%; the paraphrase layout measured 98.4%, so
  the check discriminates) and 55% at `<= 1` (model and measurement 62%).
  The sketch is only used at and below `sample_size = 10 * max_size`
  increments, which is exactly this load; the 4-bit counters are meant to
  be read as "roughly how popular", not as counts.
- 2026-10-27 (M2.2): the reset API. `reset/1` halves every word in one
  call and returns `odd`. The chunked form is `reset(sketch, cursor,
  chunk)` with the cursor `{next_word, odd}` kept by the caller, starting
  from `reset_start/0` (`{1, 0}`); it returns `{:more, cursor}` or
  `{:done, odd}`. `size_after_reset(size, odd)` is the odd-count rule
  `(size - (odd >>> 2)) >>> 1`, clamped at 0: a sketch of a few words can
  carry more odd nibbles than `4 * size` from an earlier halving (8 words
  hold 128 nibbles against a `sample_size` of 10 at `max_size` 1), and a
  negative count would be nonsense. `sample_size/1` and `reset_chunk/0` are
  functions of the module; `reset_chunk` is not a `start_link` option, since
  specs/08 lists none and the maintenance process (M2.7) can pass the
  module default.
- 2026-10-27 (M2.2): `reset_chunk` defaults to 16_384 words, not 65_536.
  Measured on the reference machine with a 2^20-word sketch 80% of whose
  words were non-zero: the first loop (64-bit shift, mask and a SWAR nibble
  count on the whole word) ran at 150 ns per word, so one 65_536-word
  chunk took 10 ms against the 5 ms `pass_budget` of specs/04 with nothing
  else in the pass. Words with their top nibble in use are above 2^59 and
  so bignums on the BEAM; every shift and mask on them allocates. Splitting
  each word into 32-bit halves before any arithmetic (the halving is the
  same, since the bit crossing from the high half is the top bit of
  nibble 7, which the mask clears; the odd count is `rem(half &&&
  0x11111111, 15)` because 16 is 1 modulo 15 and a half has only 8
  nibbles) brought the loop to 92 ns per word, close to the 55–65 ns the
  two atomics ops cost alone. At 65_536 words that is still 6 ms, so the
  default chunk is 16_384 (about 1.5 ms loaded, 0.5 ms on a zero sketch,
  which is skipped without a write). A 2^20-word sketch now resets over 64
  passes instead of 16; the sketch is lossy and specs/04 says to size caps
  from measurements. M2.11 measures the whole pass and may change the
  figure again.
