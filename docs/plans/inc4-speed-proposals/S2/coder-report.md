# S2 coder report (native SHA-256 behind the Sha256Provider seam), 2026-11-07

Clone: `.toolchain/scratch/speed-s2/coder/` (tests copied from `S2/test/`, unchanged). Patch: `S2/patch.diff` (4 files, built against the current real tree; the real tree was not modified).

## Files (4 in patch: 3 edited, 1 new)
- `lib/src/transfer/hashing.dart` (edit): `Sha256Incremental`, `IncrementalSha256Provider`, `newSha256Incremental()`, pure-Dart incremental via chunked conversion; isolate entry points resolve the best provider inside the isolate (`sha256OfPathStreamed`), inline chunk hashing uses the active provider.
- `lib/src/transfer/native_sha256.dart` (new): EVP_* (libcrypto, linux/macos) and bcrypt CNG (windows, absolute `%SystemRoot%\System32` only); slices of <=1 MiB, one native context per incremental, freed in `dispose`; KAT (NIST one-shot and incremental) with tamper hook; `LS_NO_NATIVE_SHA=1` kill switch; `resolveBestSha256Provider` (cached per isolate), `installBestSha256Provider` (idempotent).
- `lib/src/transfer/file_receiver.dart` (edit): per-chunk digest and running whole-file digest through `newSha256Incremental()`; disposed in `finally`; running hash released on every non-successful putChunk exit (F-A reset kept), on finalize (every path), on discard/cancel, and on any terminal session status; isolate fallback calls `sha256OfPathStreamed`. Removed `_DigestCapture` and the old `_sha256OfFile`.
- `lib/src/engine/libreshare_engine.dart` (edit): `installBestSha256Provider();` as the first statement of the constructor body, plus the import.

## Deviation from the contract (needed by the tests)
- `tryLoadNativeSha256` returns `NativeSha256Provider?` (a subtype of the contract's `IncrementalSha256Provider?`). `native_sha256_test.dart` reads `native!.libraryName` on its result without a cast.

## Tests (dart test -j 1, one file per run, `flock -o /tmp/libreshare-heavy.lock`)
| File | +pass | -fail | rc |
|---|---|---|---|
| unit/native_sha256_test.dart | +76 | 0 | 0 |
| unit/hashing_isolates_test.dart | +12 | 0 | 0 |
| unit/hashing_isolates_native_test.dart | +9 | 0 | 0 |
| integration/native_sha256_transfer_test.dart | +37 | 0 | 0 |
| same with LS_NO_NATIVE_SHA=1 | +37 | 0 | 0 |
| integration/receiver_verification_characterization_test.dart | +14 | 0 | 0 |
| unit/file_receiver_test.dart | +60 | 0 | 0 |
| unit/file_sender_test.dart | +47 | 0 | 0 |
| unit/hashing_test.dart | +14 | 0 | 0 |
| unit/hashing_provider_test.dart | +2 | 0 | 0 |
| unit/resume_store_test.dart | +28 | 0 | 0 |
| unit/receiver_session_wait_test.dart | +13 | 0 | 0 |
| unit/inc4_negatives_test.dart | +10 | 0 | 0 |
| unit/receive_controller_test.dart | +37 | 0 | 0 |
| integration/chunk_retry_integrity_test.dart | +2 | 0 | 0 |
| integration/receive_mode_engine_test.dart | +13 | 0 | 0 |
| integration/large_transfer_test.dart | +1 | 0 (1 skipped inside the file) | 0 |
| unit/atomic_file_adoption_test.dart | +12 | 0 | 0 |

`dart analyze --fatal-infos lib` in the clone: No issues found. `dart format` applied to the 4 files.

## UNVERIFIED
- Windows bcrypt path (`_BcryptBackend`, msvcrt malloc/free, UTF-16 algorithm name, handle slots): compiled only, never loaded on this host. Needs the windows-latest workflow.
- macOS `/usr/lib/libcrypto.dylib` path: not exercised here.
- Speed numbers (>=5x provider guard, >=3x isolate guards, >=1.5x completeFile) passed on this host; exact figures not recorded. Gate runs `tools/bench/gate.sh` separately.
- Not run: the 3x flake repeat (tester/verifier step), other suites.
