# Hit-rate traces for `mix bench hitrate` (specs/09 §`mix bench hitrate`).
# Read by Theine.Bench.Traces; `mix bench.traces` downloads or generates each
# one into bench/traces/ (gitignored) and checks it against `sha256`.
#
# `sha256` is the hash of the file as stored in bench/traces/, i.e. after
# decompression. Synthetic traces are hashed too, so a generator that stops
# being deterministic fails here instead of silently shifting hit rates.
#
# The ARC traces (Megiddo & Modha) come from the moka-rs/cache-trace mirror,
# which is the ARC source Caffeine's simulator wiki links to. The original IBM
# page is gone. Recorded on 2026-10-27 from an actual download (specs/09).
# To add a trace: set `url` (and `compression` for .gz or .zst), leave
# `sha256: nil`, run `mix bench.traces --only NAME`, and record the hash the
# failure message prints.
[
  %{
    name: "OLTP",
    format: :arc,
    file: "OLTP.lis",
    sizes: [1_000, 2_000, 5_000],
    url: "https://raw.githubusercontent.com/moka-rs/cache-trace/main/arc/OLTP.lis.zst",
    compression: :zstd,
    sha256: "01fc36ce7c40a4741e30bd1f999402295fbea829f00f3591ad6732feb078808f"
  },
  %{
    name: "DS1",
    format: :arc,
    file: "DS1.lis",
    sizes: [1_000_000, 4_000_000, 8_000_000],
    url: "https://raw.githubusercontent.com/moka-rs/cache-trace/main/arc/DS1.lis.zst",
    compression: :zstd,
    sha256: "368944c669f5aa275d87d14ec1756d7d6e083c94fd458a34a7770b7fd850b025"
  },
  %{
    name: "S3",
    format: :arc,
    file: "S3.lis",
    sizes: [100_000, 400_000],
    url: "https://raw.githubusercontent.com/moka-rs/cache-trace/main/arc/S3.lis.zst",
    compression: :zstd,
    sha256: "6d76c453c58274fb9141812b507910f77a61aa675984598f632f7c3ce4985aeb"
  },
  %{
    name: "P3",
    format: :arc,
    file: "P3.lis",
    sizes: [50_000],
    url: "https://raw.githubusercontent.com/moka-rs/cache-trace/main/arc/P3.lis.zst",
    compression: :zstd,
    sha256: "bad2e26607cb7c070075a8d17d89081e6c82a3301fc9f6568464e0969898897f"
  },
  # Cycle over 1.5 × 1_000 keys, 100 times (specs/09 §Decisions 2026-10-27, M0.4).
  %{
    name: "loop",
    format: :keys,
    file: "loop.keys",
    sizes: [1_000],
    generator: {:loop, keys: 1_500, cycles: 100},
    sha256: "722066ef09ac3f80dfc7350e01c05586c497558fce5b71256f61a63fed9a8b15"
  },
  # Zipf(0.99), 10M requests over 1M keys, fixed seed.
  %{
    name: "zipf",
    format: :keys,
    file: "zipf.keys",
    sizes: [10_000, 100_000],
    generator: {:zipf, s: 0.99, keys: 1_000_000, requests: 10_000_000, seed: 2026},
    sha256: "7851507e02a2739d6937b21db3fa5530979e73062d92bb316fd9500606a43e25"
  }
]
