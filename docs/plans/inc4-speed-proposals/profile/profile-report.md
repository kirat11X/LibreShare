# Inc4 speed profile: where the 300 MiB loopback time goes

Diagnostic only. Instrumentation is in a clone (`.toolchain/scratch/speed-prof/clone`); the real tree is unchanged. Diff: `profile-instrumentation.diff` (this folder). Logs: `.toolchain/scratch/speed-prof/logs/`.
Setup: 300 MiB loopback, `LS_C=3`, 3 runs, medians; stage numbers are ms per 4 MiB chunk (75 chunks).
## Throughput (MiB/s, median of 3; runs in brackets)
| Variant | secure (TLS 1.3) | plain |
|---|---|---|
| base | 80.5 [81.2, 80.5, 62.4] | 97.0 [128.4, 97.0, 77.1] |
| E1 no SHA-256 both sides | 91.0 [103.8, 91.0, 73.1] | 161.6 [161.6, 178.8, 131.0] |
| E2 receiver discards bytes | 109.7 [109.8, 109.7, 107.4] | 193.9 [188.1, 194.1, 193.9] |
| E3 = E1+E2 (transport ceiling) | 144.4 [144.4, 145.7, 143.8] | 261.4 [258.2, 274.0, 261.4] |
| E4 1 MiB chunks | 72.9 [74.8, 72.9, 64.6] | 106.4 [106.4, 100.2, 108.1] |

Run-to-run spread is large (62 to 128 MiB/s in base); differences under about 20% are noise.

## Per-stage cost, base (ms per 4 MiB chunk, median of 3)
| Sender stage | secure | plain |
|---|---|---|
| read chunk (RandomAccessFile) | 9.6 | 11.7 |
| hash (native SHA-256, main isolate) | 4.1 | 4.1 |
| put (await HTTP/TLS, includes waiting for ack) | 99.3 | 68.5 |
| chunk total | 112.6 | 84.3 |

| Receiver stage (handler per chunk) | secure | plain |
|---|---|---|
| total putChunk | 91.5 | 59.3 |
| waiting for body pieces | 3.5 | 1.2 |
| hash (running SHA over pieces) | 4.0 | 4.2 |
| file write (setPosition + writeFrom per piece) | 78.0 | 32.2 |
| resume-store update (bitmap persist, every 8th chunk) | 3.6 | 15.7 |
| open + close partial file | 0.6 | 5.3 |

Body pieces per chunk: secure about 513 (8 KB each, about 150 us of awaited I/O each); plain about 1.25. Stage sums overlap across the 3 in-flight chunks, so use ms per chunk, not % of wall.

## CPU and event loop (base, median of 3)
| Process | wall s | CPU s (utime+stime) | CPU/wall | Dart pool threads CPU s | main thread CPU s |
|---|---|---|---|---|---|
| sender secure | 4.41 | 3.80 | 86% | 3.56 | 0.06 |
| receiver secure | 4.81 | 6.12 | 127% | 5.68 | 0.06 |
| sender plain | 2.46 | 2.38 | 97% | 2.18 | 0.06 |
| receiver plain | 2.70 | 2.75 | 102% | 2.56 | 0.06 |

All Dart work runs on the DartWorker pool, so per-thread CPU cannot separate the main isolate from `Isolate.run` hashing workers.
Event-loop lag (1 ms timer, mean / max): sender secure 254 us / 103 ms; receiver secure 137 us / 102 ms; sender plain 308 us / 59 ms; receiver plain 470 us / 56 ms. Low mean lag does not prove the isolate is idle (short slices keep it low too); the ~100 ms max spikes are real stalls.

## Reading
- Dominant cost: the receiver's file-write path. Secure: 513 awaited positioned writes per chunk account for 78 of 91 ms. Plain: 32 ms of write (about 125 MB/s on btrfs) plus 16 ms of resume-bitmap store per chunk (average; persist itself runs every 8th chunk, so each persist is about 125 ms).
- E2 removes the write and cuts plain store from 16 to 2 ms: plain 97 to 194 MiB/s, secure 80 to 110. The sender mostly waits on the receiver's ack (put 99 ms), not hashing (4 ms).
- Hashing: E1 gives +13% secure, +67% plain (noisy). Chunk size is not the lever: E4 (1 MiB) gives no gain.
- Secure transport ceiling (E3) is 144 vs 261 plain: TLS costs about 45% even with no hashing or disk.

## Three low-risk changes, ranked (gains are estimates, marked as guesses)
1. Receiver: buffer body pieces per chunk (or per 256 KiB) and issue one positioned write per batch. Estimate: secure handler 91 to about 25 ms per chunk; secure +20 to 35% (guess). Needs tester review of out-of-order and resume paths.
2. Receiver: persist the resume bitmap every N chunks or about every 250 ms, not per chunk. Estimate: plain +10 to 15% (guess). Medium risk: resume crash-consistency must be re-reviewed against the spec.
3. Sender: keep one open RandomAccessFile per file and move read+hash of each chunk off the main isolate (Isolate.run for chunks of 1 MiB or more). Estimate: 0 to 5% (guess); helps plain, where the sender is near one full core.

## Caveats
- 3 runs per cell, medians only; other agents shared the machine and heavy lock. E2/E3 skip the byte compare (empty file by design) and check only `status=COMPLETED`.
- Bench bug fixed in the clone: `tools/env.sh` overwrote `ROOT`, so the first attempt ran the uninstrumented snapshot. The real tree was not rebuilt or modified.
- The diff includes a debug `LS_PROF_TRACE` line (clone-only, env-gated).
