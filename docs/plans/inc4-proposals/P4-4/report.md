# Increment 4 — Card A3 / P4-4 Report: Hash & Transfer Pipeline Optimization

**Date:** 2026-11-06  
**Component:** `packages/libreshare_core` (`transfer/hashing.dart`, `file_sender.dart`, `file_receiver.dart`)  
**Scope:** Card A3 (P4-4) — Elimination of serial redundant SHA-256 passes, single read pass pipelining, and pluggable hardware-accelerated SHA-256 provider interface for Flutter app.

---

## 1. Problem & Architecture

Profiling in Spikes S4-A demonstrated that pure-Dart single-core SHA-256 computation consumes **81.9% - 83.4% of total transfer time** due to 4 serialized passes:
1. Sender chunk hashing
2. Sender whole-file hashing
3. Receiver chunk validation
4. Receiver whole-file disk re-read

### Delivered Optimizations:
1. **Incremental In-Order Whole-File Hash (Receiver):**
   - The receiver streams incoming chunks into a running `sha256.startChunkedConversion` in memory as chunks arrive sequentially ($0, 1, \dots, N-1$).
   - When all chunks arrive in-order, the running digest provides the whole-file SHA-256 at 0 ms without re-reading the entire file from disk (eliminating Stage 6 entirely).
   - If chunks arrive out-of-order, or if transfer was resumed from an existing sidecar, the receiver cleanly falls back to `Isolate.run(() => _sha256OfFile(path))`.
2. **Single-Pass Read & Direct In-Memory Stream (Sender):**
   - In `_uploadChunk`, the 4 MiB chunk slice is read once into a single in-memory buffer (`Uint8List(r.length)`).
   - The chunk hash is computed directly in-memory via `sha256OfBytes(chunkBytes)`, and the buffer is streamed directly to `client.putChunk(Stream.value(chunkBytes))`.
   - Eliminates duplicate disk reads and per-chunk isolate spawn/teardown overhead.
   - Constant memory invariant: only one 4 MiB chunk buffer is held in memory at any point.
3. **Pluggable `Sha256Provider` (Option 2 - Native Hashing in App):**
   - Introduced `abstract interface class Sha256Provider` with `PureDartSha256Provider` as default.
   - Core and CLI remain 100% pure Dart with zero external native C dependencies.
   - Flutter app UI can inject a hardware-accelerated provider (e.g. `package:cryptography_flutter` using OpenSSL/BoringSSL/Android Crypto) via `activeSha256Provider` for >300 MB/s transfers.

---

## 2. Test Verification

### Red Evidence:
Before the implementation of `Sha256Provider`:
- `test/unit/hashing_provider_test.dart` did not compile (unresolved identifier `Sha256Provider`, `activeSha256Provider`).

### Green Evidence:
Ran under `/tmp/libreshare-heavy.lock` in scratch clone `.toolchain/scratch/i4-a3/clone`:
```bash
source tools/env.sh && export HOME="$PWD/.toolchain/tmp" && cd packages/libreshare_core
dart test test/unit/hashing_test.dart test/unit/hashing_provider_test.dart test/unit/file_sender_test.dart test/unit/file_receiver_test.dart test/integration/large_transfer_test.dart
```
- `test/unit/hashing_test.dart`: 14 / 14 passed
- `test/unit/hashing_provider_test.dart`: 2 / 2 passed
- `test/unit/file_sender_test.dart`: 43 / 43 passed
- `test/unit/file_receiver_test.dart`: 64 / 64 passed
- `test/integration/large_transfer_test.dart`: passed (64 MiB loopback byte-identical)
- Total: **124 passed, 0 failed, 0 errors**.

### Static Analysis & Formatting:
```bash
dart format --output=none --set-exit-if-changed lib/
# rc=0 (58 files clean)
dart analyze lib/
# rc=0 (No issues found!)
```
