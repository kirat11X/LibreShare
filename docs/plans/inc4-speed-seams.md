# Speed work, wave S2: native SHA-256 behind the existing seam (contract; owner: orchestrator)

Plan: `docs/plans/inc4-speed.md`. Measurement that justifies this wave: `docs/test-reports/inc4-spikes.md` section "S0" (libcrypto FFI 1087 MiB/s vs pure Dart 73 MiB/s on one core). Tester writes tests from THIS file first and shows them red; the coder makes them green without touching the tests; a different agent verifies with a mutation table. Security-critical (it decides whether a file's integrity check can be fooled): medium coder at least, second tester review.

## 1. Files and who may edit them
- Edit: `packages/libreshare_core/lib/src/transfer/hashing.dart`, `.../transfer/file_receiver.dart` (only the hasher/runningHasher call sites and the whole-file fallback), `.../engine/libreshare_engine.dart` (only one call to `installBestSha256Provider()` in the constructor).
- New: `.../transfer/native_sha256.dart`.
- Do NOT touch: `protocol.dart`, `model/*`, `chunker.dart`, interfaces in `server/incoming_transfer_handler.dart` and `client/peer_client.dart`, any wire/TLS code, any existing test. `package:ffi` is already in `pubspec.lock` (via Flutter); if the coder needs it in `packages/libreshare_core/pubspec.yaml` they report instead of editing (pubspec is orchestrator-owned). Preferred: no new dependency, use `dart:ffi` + libc/system `malloc` lookups as `test/helpers/port_blocker.dart` does.
- `packages/libreshare_core` must not import Flutter.

## 2. Public API (names are fixed; tests import `package:libreshare_core/src/transfer/hashing.dart` and `.../native_sha256.dart`)
```dart
// hashing.dart (additions; existing names and behaviour unchanged)
abstract interface class Sha256Incremental {
  void add(List<int> data);          // any List<int>, incl. Uint8List views with offsetInBytes != 0
  String finishHex();                // lowercase hex; once only
  void dispose();                    // frees native state; idempotent; legal after finishHex
}
abstract interface class IncrementalSha256Provider implements Sha256Provider {
  Sha256Incremental startIncremental();
}
// PureDartSha256Provider now also implements IncrementalSha256Provider.
Sha256Incremental newSha256Incremental();   // active provider's if it is incremental, else a pure-Dart wrapper

// native_sha256.dart
class NativeSha256Provider implements IncrementalSha256Provider { String get libraryName; }
List<String> nativeSha256Candidates({required String os, Map<String, String>? env});
IncrementalSha256Provider? tryLoadNativeSha256({
  List<String>? candidates,                    // default: nativeSha256Candidates(os: Platform.operatingSystem, env: Platform.environment)
  String Function(String hex)? tamperDigestForTest,   // applied to every digest the candidate returns BEFORE the known-answer test
});
IncrementalSha256Provider installBestSha256Provider({bool allowNative = true});   // sets activeSha256Provider and returns it; idempotent
```

## 3. Behaviour that must hold
1. **Same digests as package:crypto** for every input: NIST vectors ("", "abc", 1,000,000 x "a"), lengths 0, 1, 55, 56, 63, 64, 65, 4 MiB - 1, 4 MiB, 4 MiB + 1, seeded random data split into random piece sizes 1..64 KiB (incremental), `Uint8List.sublistView` slices, plain `<int>[...]` lists.
2. **Load-time known-answer test (KAT):** `tryLoadNativeSha256` hashes the NIST vectors (one-shot and incremental) and compares with expected constants compiled into the code; any mismatch, any exception, a missing library or `tamperDigestForTest` that changes a digest returns `null`. It never throws.
3. **Fallback is silent and safe:** `installBestSha256Provider(allowNative: false)` or the environment variable `LS_NO_NATIVE_SHA=1` selects `PureDartSha256Provider`; a failing load also selects it. The transfer works the same with either.
4. **Library search is not hijackable:** `nativeSha256Candidates(os: 'windows', env: {'SystemRoot': r'C:\Windows'})` returns only absolute paths below `%SystemRoot%\System32` (bcrypt); with no/relative `SystemRoot` it returns an empty list. `linux` returns the bare names `libcrypto.so.3`, `libcrypto.so.1.1`, `libcrypto.so` (resolved by the system loader); `macos` returns `/usr/lib/libcrypto.dylib`; `android` and `ios` return an empty list (pool path later, wave S1).
5. **Isolates:** `sha256OfFile`, `sha256OfChunk` and the receiver's whole-file fallback run in spawned isolates where globals are fresh: they must obtain the best provider inside the isolate (the provider object is not sendable). Digest, `FileSystemException` on a missing file and the "File shorter than expected: chunk N has X of Y bytes" message stay exactly as today.
6. **Receiver verification stays on:** the per-chunk digest (`X-Chunk-Sha256`) and the whole-file digest are still computed over exactly the received bytes and compared before the chunk is acked / the file is COMPLETED, using `newSha256Incremental()`. A flipped bit in a chunk body still yields the existing chunk-hash error; a wrong whole-file hash still yields FAILED/`verifyFailed` and removes the partial file; out-of-order chunks still disable the running whole-file hash and fall back to the file re-hash.
7. **Resource safety:** 10,000 start/dispose cycles do not grow RSS by more than 20 MB; 1,000 interleaved incrementals produce independent correct digests; `add`/`finishHex` after `finishHex` throws `StateError`; `dispose()` twice is fine; an exception thrown by a transfer between `start` and `finish` must not leak the native context (the receiver disposes in `finally`).
8. **Engine:** constructing `LibreShareEngine` installs the best provider once (idempotent), so UI and CLI get it without their own code.
9. **Coarse speed guard (relative, not absolute):** where a native provider loads, hashing 64 MiB through it is at least 5x faster than through `PureDartSha256Provider` in the same process; where none loads, the test asserts the provider is pure Dart.

## 4. Mutation table the verifier must run (each must turn a named test red)
M1 skip the KAT; M2 `finishHex` returns the digest of the previous buffer; M3 piece offset ignored for views (`offsetInBytes`); M4 receiver stops comparing the chunk digest; M5 receiver compares the whole-file digest against the chunk digest; M6 provider chosen even when `LS_NO_NATIVE_SHA=1`; M7 Windows candidate list accepts a relative path; M8 `dispose` not called on the error path (leak test); M9 isolate functions keep using pure Dart only (speed guard) ; M10 native add ignores the last partial block (length tests).

## 5. Gate (orchestrator, alone, real exit codes)
analyze `--fatal-infos`, format, core `dart test`, CLI `dart test`, app `flutter test`, the new tests 3x, `tools/bench/gate.sh --run` (expect plain and secure both clearly above 14.9 / 19.9 MiB/s; the exact numbers are recorded, not promised), `LS_NO_NATIVE_SHA=1` run of the new transfer test, Windows part marked UNVERIFIED on this host (to be exercised by the windows-latest workflow).

## 6. Orchestrator decisions on the tester's gaps (2026-11-07 ~20:20)
1. Failed-load simulation for `installBestSha256Provider`: not needed; `tryLoadNativeSha256` returning null plus `allowNative:false` are the tested paths.
2. "Idempotent" = same runtime type; fine. 3. Behaviour after `dispose()` is unspecified; not tested. 4. Windows list tested with the pure function; bcrypt loading is UNVERIFIED on this host (windows-latest workflow later) and logged in DEEP_REVIEW_QUEUE.
5. Thresholds accepted: isolate functions 3x, receiver `completeFile` re-hash 1.5x, contract-level 5x for the in-process provider comparison.
6. The receiver MUST dispose its running whole-file incremental when the file completes, fails or is cancelled (not at `FileReceiver.dispose()` only); the cancel test stays as written.
7. Sequencing: wave F-A (inc4-proposals/F-A: running-hash reset, /state range validation, lost-ack check, persist per ack) touches the same receiver lines; S2 is coded on top of the applied F-A. The running-hash reset of F-A must be kept (with the new `Sha256Incremental`: dispose + null on every non-successful exit).
