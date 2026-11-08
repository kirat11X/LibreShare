# S2 tester report (native SHA-256), 2026-11-07

Role: tester, tests first, production code untouched (clone `.toolchain/scratch/speed-s2/clone`, `lib/` identical to the real tree). Contract: `docs/plans/inc4-speed-seams.md`. Copies of every file are in `docs/plans/inc4-speed-proposals/S2/test/` (same relative paths as under `packages/libreshare_core/test/`). The coder copies them into `packages/libreshare_core/test/` (orchestrator step).

## Files (7, all new; no existing test touched)
| File | Status today | Contract |
|---|---|---|
| `unit/native_sha256_test.dart` | RED (compile) | 1, 2, 3, 4, 7, 9 |
| `unit/native_sha256_child.dart` | helper process, not a test | 3 (LS_NO_NATIVE_SHA) |
| `unit/hashing_isolates_test.dart` | CHARACTERIZATION, green today (12 tests) | 5 |
| `unit/hashing_isolates_native_test.dart` | RED (compile) | 5, M9 |
| `integration/native_sha256_transfer_test.dart` | RED (compile) | 6, 7, 8, M9 (receiver) |
| `integration/receiver_verification_characterization_test.dart` | CHARACTERIZATION, green today (14 tests) | 6 |
| `helpers/s2_verification_scenarios.dart` | shared scenarios (uses no S2 symbol) | 6 |

The brief asked for three files; I split the parts that are meaningful today into two characterization files so they can be shown green and must stay green. The scenarios are shared through the helper (deviation from "self-contained", only for this reason). No ports are used: engines bind port 0 and receiver tests call `FileReceiver` directly (53410-53430 not needed).

## RED (production untouched, `flock -o /tmp/libreshare-heavy.lock dart test <file>`, run in `packages/libreshare_core` of the clone)
- `native_sha256_test.dart` rc=1: `Failed to load ... Error when reading 'lib/src/transfer/native_sha256.dart': No such file or directory`, then `Type 'Sha256Incremental' not found`, `Method not found: 'tryLoadNativeSha256'`.
- `hashing_isolates_native_test.dart` rc=1: same missing file, `Method not found: 'installBestSha256Provider'`.
- `native_sha256_transfer_test.dart` rc=1: same missing file, `Type 'IncrementalSha256Provider' not found`.
`dart analyze` of the three shows only missing-symbol errors (nothing else), so apart from those the files type-check. I could NOT run them green against an implementation (no lib edits allowed, not even in the clone): expect the verifier/coder phase to find any logic slip in the tests; report it, do not weaken.

## CHARACTERIZATION (green today, must stay green)
`hashing_isolates_test.dart` 12/12 rc=0 and `receiver_verification_characterization_test.dart` 14/14 rc=0, each run 3x (rc 0,0,0; 1 s and 23 s). Files are deterministic (seeded).

## Test names -> contract
- B1 (digests): `native_sha256_test` groups `behaviour 1 [pure-dart|native]`: NIST vectors, lengths 0/1/55/56/63/64/65/4MiB-1/4MiB/4MiB+1 (one-shot, single add, random splits, byte-at-a-time <=130), 5 seeded random splits 1..64 KiB, views with offsetInBytes != 0, plain List<int>, no-stale-buffer, hashStream (also error and empty).
- B2 (KAT): `behaviour 2` group: identity hook control (called >= 3 times), 7 tamper variants (each NIST vector alone, first/last nibble, empty, zeros), throwing hook, missing/garbage/directory/non-crypto candidates, missing candidate skipped then a good one, fresh isolate load.
- B3: `behaviour 3` group: allowNative:false, default pick + idempotent + switch back, child process with LS_NO_NATIVE_SHA=1 (env passed only to the child, `includeParentEnvironment:false`) and without it.
- B4: `behaviour 4` group: linux/macos/android/ios lists, Windows with SystemRoot (C:\Windows, D:\WINNT), no/relative/drive-relative SystemRoot -> empty, never a relative path.
- B5: `hashing_isolates_test` (digest 0-byte, 4 MiB+1, 20 MiB; FileSystemException; exact "File shorter than expected: chunk N has X of Y bytes", inline and isolate size) plus the same under both provider modes in `hashing_isolates_native_test`.
- B6: `defineReceiverVerificationTests` (helper), run default (characterization) and under `installBestSha256Provider(allowNative: true|false)`: in-order / first-chunk-last / gap-in-middle COMPLETED with identical bytes; flipped bit (middle, first byte, last byte of short last chunk) -> chunkHashMismatch, not stored, resend completes; no chunk header + flipped bit -> FAILED/verifyFailed and no partial; wrong manifest hash -> FAILED/verifyFailed and no partial (3 orders each); hash supplied at /complete.
- B6 engine: 24 MiB, 6 x 4 MiB engine->engine, cmp-identical, both modes.
- B7: `native_sha256_test` misuse (StateError, double dispose), 1,000 interleaved, 10,000 cycles RSS < 20 MB (native 64 KiB per cycle); `transfer_test` group `behaviour 6/7`: counting provider asserts started >= chunks and started == disposed after in-order, tampered chunk, body throwing mid-chunk, too-short body, wrong whole-file hash, out-of-order, session cancelled mid-file.
- B8: `behaviour 8` group (engine construction installs native when it loads; with LS_NO_NATIVE_SHA=1 in the parent env it only requires an incremental provider).
- B9: `behaviour 9` group (>= 5x on 64 MiB; else asserts pure Dart is active).

## Mutation table M1-M10 -> expected catcher
- M1 skip KAT: `KAT rejects: ...` (7 variants) and the throwing hook.
- M2 stale digest: `no stale buffer`, NIST vectors, interleaved 1,000.
- M3 view offset ignored: `Uint8List views with offsetInBytes != 0`; transfer tests (piece views).
- M4 chunk digest not compared: tamper tests in all three receiver runs (flipped bit x3).
- M5 whole-file compared with chunk digest: every happy path fails; `wrong manifest hash`.
- M6 LS_NO_NATIVE_SHA ignored: child-process test.
- M7 relative Windows path accepted: `relative / unusable SystemRoot`, `no candidate is ever a bare / relative name`.
- M8 dispose missing on error path: `behaviour 6/7` leak tests (tampered, mid-chunk throw, short body, wrong hash, cancel) plus the 10,000-cycle RSS test only if the mutant leaks at the provider level.
- M9 isolates stay pure Dart: `hashing_isolates_native_test` M9 (sha256OfFile and sha256OfChunk, >= 3x) and the receiver fallback speed test (completeFile on 96 MiB out of order, >= 1.5x vs package:crypto). These timings are relative, so a very loaded machine could flake; threshold margins are wide (native expected ~10x).
- M10 last partial block ignored: length tests 1/55/56/63/65, 4 MiB+1, NIST "abc", 1M x "a" (997-byte pieces).
No mutant is known to escape. Not covered by any test: a receiver that skips the per-chunk hash but hashes some other way is only detected through behaviour (tamper tests), which is what is wanted.

## Gaps / ambiguities (reported, not decided)
1. `installBestSha256Provider` has no injection point for "load fails"; B3 "failing load also selects pure Dart" is covered only through `tryLoadNativeSha256` returning null (candidate tests), not through installBest.
2. "idempotent" is tested as same runtimeType and active==returned, not `identical` instances.
3. Behaviour after `dispose()` then `add`/`finishHex` is unspecified: not tested.
4. Is the digest hook called for every NIST vector (I require >= 3 calls)? "applied to every digest" implies it.
5. Windows candidate rules: UNC roots (`\\server\share`), rooted-without-drive (`\Windows`), `..` inside SystemRoot, and case of the env key (`SYSTEMROOT`) are unspecified, not tested. Windows paths are tested with the pure function on every host; actual bcrypt loading is UNVERIFIED on this machine.
6. Candidates are assumed to be tried in order with a failing one skipped (test `a missing candidate is skipped`).
7. macOS: not asserted that a native provider loads (hostHasNativeLibrary is true only on Linux with libcrypto and on Windows).
8. The 5x guard applies to the provider; for the isolate functions I used 3x (sha256OfFile/Chunk) and 1.5x (completeFile, includes fsync/rename), because spawn and I/O dilute the ratio. Orchestrator decides if that is right.
9. Tamper tests that must run per hash mode use `FileReceiver` directly (not a hostile proxy): the receiver is the unit under test.
10. Receiver scenarios use 24 MiB - 37 bytes (6 chunks, short last) to cover a partial final block; the engine test uses exactly 24 MiB.
11. Leak counting assumes the receiver releases the running whole-file incremental when the file ends, fails or the session is cancelled/disposed (contract 7). If the coder keeps it until `FileReceiver.dispose()`, the cancel test will say so; that is the intended strictness.

## Commands (from `packages/libreshare_core`, `source tools/env.sh`, `export TMPDIR=$REPO/.toolchain/tmp`)
```
flock -o /tmp/libreshare-heavy.lock dart test test/unit/native_sha256_test.dart
flock -o /tmp/libreshare-heavy.lock dart test test/unit/hashing_isolates_test.dart
flock -o /tmp/libreshare-heavy.lock dart test test/unit/hashing_isolates_native_test.dart
flock -o /tmp/libreshare-heavy.lock dart test test/integration/native_sha256_transfer_test.dart
flock -o /tmp/libreshare-heavy.lock dart test test/integration/receiver_verification_characterization_test.dart
LS_NO_NATIVE_SHA=1 flock -o /tmp/libreshare-heavy.lock dart test test/integration/native_sha256_transfer_test.dart   # gate step
```
