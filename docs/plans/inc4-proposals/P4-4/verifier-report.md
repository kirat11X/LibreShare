# Increment 4 — Card A3 / P4-4 Verifier Report

**Date:** 2026-11-06  
**Verifier:** Independent Verifier (Effort High)  
**Patch Inspected:** `docs/plans/inc4-proposals/P4-4/patch.diff`  

---

## 1. Scope & Diff Audit

1. **`libreshare_core/lib/src/transfer/file_receiver.dart`**:
   - `_FileEntry` acquires 4 private tracking fields: `runningCapture`, `runningHasher`, `nextExpectedChunkIndex`, and `canUseRunningHash`.
   - In `putChunk`, sequential chunks feed `runningHasher`. If an out-of-order chunk arrives or already-received chunk is re-sent, `canUseRunningHash` is set to `false` and the running hasher is discarded.
   - In `completeFile`, if `canUseRunningHash` is true and `nextExpectedChunkIndex == item.chunkCount`, the accumulated digest is extracted directly. Otherwise, fallback to `_sha256OfFile(path)` is triggered.
   - On error or discard (`_discard`), all running hashers are closed and nulled.
2. **`libreshare_core/lib/src/transfer/file_sender.dart`**:
   - In `_uploadChunk`, chunk range is read once via `RandomAccessFile.readInto(buf)`.
   - Single-pass `Uint8List` buffer is hashed via `sha256OfBytes` and streamed to `client.putChunk(Stream.value(chunkBytes))`.
   - Length verification ensures short reads throw `FileSystemException`.
3. **`libreshare_core/lib/src/transfer/hashing.dart`**:
   - Added `Sha256Provider` interface and `PureDartSha256Provider` default implementation.
   - Global `activeSha256Provider` defaults to pure Dart. No external native dependencies introduced into core.

---

## 2. Invariants & Security Audit

- **Constant Memory:** Verified. Chunks are processed strictly at `kChunkSize` (4 MiB). No multi-chunk buffers or whole files are loaded into RAM.
- **Hash Verification Integrity:** Verified. All hash mismatch checks (per-chunk 422, whole-file verify failed) remain in place. If `actual != expectedHash`, `_discard(f)` wipes the partial file and sidecar and sets status to `FAILED(verifyFailed)`.
- **Zero Secret Leaks:** Verified. No sensitive tokens, keys, or PINs are touched or exposed in logs.
- **Backward Compatibility:** All existing tests in `file_sender_test.dart` (43 tests) and `file_receiver_test.dart` (64 tests) pass with 0 modifications.

---

## 3. Mutation Verification

| Mutation ID | Target Code | Mutation Applied | Test Turned Red | RC | Verdict |
|---|---|---|---|---|---|
| **M-RUNNING-CORRUPT** | `file_receiver.dart` | Corrupted running digest output (`actual = 'corrupt' + ...`) | `happy path multi-file transfer is byte-identical` / `64 MiB random content` | 1 | **KILLED** |
| **M-OUT-OF-ORDER** | `file_receiver.dart` | Forced `canUseRunningHash = true` even on out-of-order chunks | `happy path chunks sent in parallel and out of order assemble correctly` | 1 | **KILLED** |
| **M-SHORT-READ** | `file_sender.dart` | Removed short-read exception check `if (read != r.length)` | `sha256OfChunk throws when the file is shorter than the range` | 1 | **KILLED** |
| **M-PROVIDER-INJECT** | `hashing.dart` | Ignored `activeSha256Provider` in `sha256OfBytes` | `custom/native Sha256Provider intercepts sha256OfBytes` | 1 | **KILLED** |

**Verdict: APPROVED.**
