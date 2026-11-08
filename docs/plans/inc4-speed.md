# Inc 4 speed plan: transfer-speed modes and targets (answers decision D1)

Status: PLAN (orchestrator, 2026-11-07). Origin: user message 2026-11-07 ~19:30: "make sure the speeds are high whatever means, like give options slow mode, high speed modes etc, so it kind of beats hard disks and pendrives easily and is good enough on SSDs, and after that make sure Inc 4 is completed". This replaces the open question D1 of `inc4.md` section 2/11 (NFR-02 target). Inc 4 is not done until this plan's acceptance holds.

## 1. What the hardware allows (so the target is honest)

| Thing | Typical sequential speed |
|---|---|
| USB 2.0 pendrive write | 15-35 MB/s |
| USB 3 pendrive write | 60-200 MB/s |
| 2.5" / 3.5" HDD | 80-200 MB/s |
| SATA SSD | 400-550 MB/s |
| NVMe SSD | 1500-6000 MB/s |
| Wi-Fi 5/6, real | 30-120 MB/s |
| Gigabit Ethernet | about 112 MB/s |
| 2.5 GbE / 10 GbE | about 280 / 1100 MB/s |

"Beats pendrives and HDDs easily" therefore means: the app must never be the bottleneck below about 200 MB/s per transfer. "Good on SSDs" means 400+ MB/s where the link allows it (loopback, 2.5/10 GbE). On Wi-Fi or gigabit the link is the cap, not the app; the plan makes sure it is the only cap.

Today (measured 2026-11-07, `tools/bench/gate.sh --run`, loopback): plain 19.9 MiB/s, secure 14.9 MiB/s. The app is 5-10x slower than an HDD.

## 2. Where the time goes (profile + code read)

`docs/test-reports/inc4-spikes.md`: pure-Dart SHA-256 is about 70 MiB/s and takes 83 % of the transfer time; TLS alone does 122 MiB/s, plain HTTP 520 MiB/s, disks 3+ GiB/s. Code read of the live path (2026-11-07, current tree):
- sender, per 4 MiB chunk: read into a buffer, then `sha256OfBytes(chunkBytes)` at `file_sender.dart:609` runs pure Dart ON THE MAIN ISOLATE (about 57 ms per chunk), the same isolate that does TLS and HTTP. Plus the whole-file digest `sha256OfFile` (`file_sender.dart:502`) in a background isolate: a second full read, but off the main isolate.
- receiver, per chunk: `hasher.add(piece)` (chunk digest, `file_receiver.dart:703`) AND, for in-order chunks, `f.runningHasher.add(piece)` (whole-file digest, `:710`): TWO pure-Dart SHA-256 passes over every byte, both on the main isolate. The whole-file pass is only skipped when chunks arrive out of order (then `Isolate.run(_sha256OfFile)` at `:878` re-reads the file).
- So each side's main isolate spends about 57 ms (sender) and about 115 ms (receiver) of hashing per 4 MiB. That alone caps the receiver near 35 MiB/s before TLS, HTTP parsing and disk are counted; measured end-to-end is 14.9 (secure) / 19.9 (plain) MiB/s.
`Sha256Provider` / `activeSha256Provider` (hashing.dart) already exist as the seam; the default is pure Dart. The P4-4 "pipeline" removed the double disk read but did not change throughput.

Two levers, and which wins is measured in S0 (not guessed):
- **Native SHA-256 by FFI** (libcrypto on Linux, bcrypt/CNG on Windows): about 1.5-2 GB/s per core with SHA instructions, so a synchronous call on the main isolate costs about 2-3 ms per 4 MiB instead of 57 ms; no pool needed on the first-class platforms. Android cannot link the system libcrypto, macOS/others fall back.
- **Hash worker pool** (long-lived isolates, `TransferableTypedData`): moves the 70 MiB/s pure-Dart cost off the main isolate, scales with cores, works everywhere (this is the Android/fallback path and the safety net when the native library is missing). The receiver's whole-file digest moves to ONE worker per file fed the in-order bytes (SHA-256 cannot be combined from chunk digests).

## 3. Modes (names fixed here; chosen per side, NOT on the wire, no protocol change)

| Mode | Intent | Hash workers | chunkConcurrency | Disk policy | Target (loopback, this machine) |
|---|---|---|---|---|---|
| `eco` | battery, old CPUs, slow media | 1 | 1 | sequential, single fsync at the end | >= 25 MiB/s, <= 1 core |
| `balanced` (default) | everyday | min(cores-1, 2) | 3 | sequential-friendly window | >= 100 MiB/s plain, >= 70 MiB/s secure |
| `turbo` | SSDs, fast links | min(cores-1, 6) (+ native SHA when available) | 6 | window sized for SSD | >= 300 MiB/s plain, >= 100 MiB/s secure (TLS ceiling below) |

Invariants in EVERY mode: TLS 1.3 profile unchanged, every chunk SHA-256 verified before it is acked, the whole-file SHA-256 verified before COMPLETED, PIN guard and pinning untouched. Modes change parallelism and I/O policy only; turbo never skips a check. CLI `--speed eco|balanced|turbo`, app Settings "Transfer speed" selector (persisted), engine option `SpeedMode`.

TLS ceiling: Dart's `SecureSocket` encrypts on the isolate's thread, about 122 MiB/s per connection measured. That is above HDD/pendrive/gigabit speeds, below SATA/NVMe on a 10 GbE link. Multi-isolate TLS would be a large refactor and is NOT in this plan (see section 8).

## 4. Waves (tests first; roles per CLAUDE.md; at most 2 agents at once; every lib patch ends with the FULL core + CLI + app suites)

- **S0 measure (0.5 d, scratch only, no lib change).** Standalone Dart script in `.toolchain/scratch/speed-s0/`: (a) pure Dart vs libcrypto FFI (`EVP_*`) SHA-256 on 4 MiB buffers, one core; (b) a 1-6 worker isolate pool with `TransferableTypedData` (aggregate MiB/s, copy overhead); (c) the existing live path with per-stage `Stopwatch` timers around a copy of the sender/receiver hot loops, plain and secure. Output: a "live path" table appended to `docs/test-reports/inc4-spikes.md` and the decision which of S1/S2 comes first.
- **S1 hash worker pool (after S2; 3 d, `transfer/hash_pool.dart`).** Long-lived isolates (`TransferableTypedData`, no per-call spawn), sized by mode; chunk hashing leaves the main isolate on both sides; receiver computes the whole-file digest incrementally from the in-order chunk stream (no second read; fallback to the isolate pass when chunks arrive out of order); sender reuses one read. Tests: golden digests, out-of-order, truncated, 0-byte, 4 MiB boundary, pool shutdown, worker crash falls back to inline (never hangs), no isolate leak, memory bound (workers x 4 MiB <= 64 MiB). Mutations: hash skipped, wrong chunk to wrong index, whole-file check skipped, pool never closed.
- **S2 native SHA-256 (FIRST, 2-3 d; S0 measured 1087 vs 73 MiB/s on one core, see inc4-spikes.md).** `NativeSha256Provider` via `dart:ffi` to system libcrypto (Linux/macOS) and bcrypt (Windows); lazy load, pure-Dart fallback on any failure; Android/iOS use the pool only. Free (system libraries). Golden tests against the pure-Dart provider.
- **S3 modes plumbing (2 d).** `SpeedMode` contract file `transfer/speed_mode.dart` (orchestrator-owned), engine/CLI/app wiring, l10n strings, persisted setting, defaults `balanced`.
- **S4 disk policy for slow media (1-2 d).** Preallocate the target, sequential-friendly writes with a bounded reorder window, one fsync at the end (not per chunk). Test with a throttled-writer double that penalises non-sequential offsets and proves the seek count drops; real HDD/pendrive runs are the user's (hardware).
- **S5 bench and gate (1 d).** `bench_lan.sh` per mode and profile (CSV gets a `mode` column); `gate.sh` with per-mode minima from section 3 and the 20 % regression rule against the new baseline; Docker bridge step p per mode. The gate must FAIL when a number is missed (mutation: lower a number, gate goes red).

## 5. Acceptance (all by real exit codes, run alone, `flock -o`)
- Section 9 of `inc4.md` (format, analyze, core, CLI, app, bench, gate, Docker e2e, package, smoke) plus: per-mode gate green on this machine; eco/balanced/turbo each recorded in the CSV; a 1 GiB loopback run per mode with `cmp`-identical output; the speed tests mutation-checked; no existing test weakened.
- Docker e2e steps m, n, o must be REAL first (see STATUS.md, 2026-11-07 19:50 audit).

## 6. Effort (estimate): about 10-12 person-days of agent work (S0 0.5, S1 3, S2 0-3, S3 2, S4 1.5, S5 1).

## 7. Risks
Isolate copy cost (use `TransferableTypedData`); Android battery/CPU (phones default to `balanced`, never `turbo` automatically); native library availability (always a pure-Dart fallback); the receiver's out-of-order writes on rotating media (S4); the TLS single-thread ceiling (documented, not hidden).

## 8. Not in this plan
Protocol or crypto changes (skip-hash, Merkle trees, QUIC), multi-isolate TLS (a possible Inc 4b if 10 GbE / NVMe-to-NVMe on secure becomes a goal), any real-hardware claim about specific pendrives or HDDs (needs the user's devices).

## 9. Decisions taken (the user can change them)
`eco | balanced | turbo`, default `balanced`; FFI to system crypto libraries allowed (free, "whatever means"); chunk size stays 4 MiB (protocol constant); modes are local settings, not negotiated.
