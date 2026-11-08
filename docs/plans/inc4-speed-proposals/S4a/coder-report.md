# S4a coder report (putChunk buffering)

Change: file_receiver.dart putChunk only. Chunks with expected <= 8 MiB are copied into Uint8List(expected), digested once (hasher.add(buffer)), checked exactly as before, then the running hash gets one add and the partial file gets one setPosition+writeFrom (only when not already stored, only after the digest check). Larger chunks keep the piece-by-piece path. Errors, F-A release, disposal, idempotency and cancellation code unchanged.

Tests (clone, flock -o heavy, dart test -j 1): 51 files, 51 rc=0, 0 failures (list in /home/kirat/coding/Software Engineering LibreShare/.toolchain/tmp/s4a_results.txt). Includes receiver_verification_characterization, native_sha256_transfer, chunk_retry_integrity, inc4_negatives, secure_two_engine, large_transfer, and every test/ file mentioning file_receiver|putChunk|FileReceiver|resume|lspart. dart analyze --fatal-infos on the file: clean. dart format: clean.

Bench (300 MiB, LS_C=3, loopback):
| run | secure MiB/s | plain MiB/s |
|---|---|---|
| before (real tree) | 86.0 | 134.4 |
| after 1 | 92.3 | 122.5 |
| after 2 | 91.5 | 124.3 |
| after 3 | 92.7 | 121.5 |

Honest read: secure +~7% (86 -> ~92). Plain DROPPED ~9% (134 -> ~123), consistently across 3 runs; the buffer copy is extra work on the plain path that does not pay off there. Keep for secure gain only if the orchestrator accepts the plain regression; otherwise restrict buffering to the secure path.

Patch: /home/kirat/coding/Software Engineering LibreShare/docs/plans/inc4-speed-proposals/S4a/patch.diff (dry-run from real tree: rc=0). Bench logs: /home/kirat/coding/Software Engineering LibreShare/.toolchain/scratch/speed-s4a/before.csv, after.csv.
