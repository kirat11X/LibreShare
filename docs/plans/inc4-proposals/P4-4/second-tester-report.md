# Increment 4 — Card A3 / P4-4 Second Tester Security & Integrity Review

**Date:** 2026-11-06  
**Reviewer:** Second Tester (Security-Critical Package Audit)  
**Package:** `packages/libreshare_core/lib/src/transfer/`  

---

## 1. Threat Modeling & Security Checks

### 1.1 Out-of-Order / Adversarial Chunk Injection
- **Attack Scenario:** An attacker sends chunk 2 before chunk 1, or re-sends a previously corrupted chunk, attempting to trick the receiver into calculating a valid whole-file hash.
- **Defense Verification:** Line 706 of `file_receiver.dart`:
  `inOrderForRunning = f.canUseRunningHash && index == f.nextExpectedChunkIndex && !already;`
  If `index != f.nextExpectedChunkIndex` or if chunk was already received:
  - `f.canUseRunningHash` is immediately set to `false`.
  - `f.runningHasher` is closed and nulled.
  - In `completeFile`, the receiver detects `!f.canUseRunningHash` and performs a full disk stream hash via `_sha256OfFile(path)`.
- **Verdict:** PASS. Malicious reordering cannot bypass whole-file integrity checks.

### 1.2 Resume & Crash Recovery
- **Scenario:** Receiver crashed mid-transfer with 12 of 25 chunks received. On restart, sender resumes and delivers chunks 12 to 24.
- **Defense Verification:** On restart, `f.nextExpectedChunkIndex` initializes to `0`, but incoming chunks start at `12`. Because `12 != 0`, `canUseRunningHash` is set to `false`. When completed, the receiver hashes the entire assembled partial file from disk, correctly verifying integrity.
- **Verdict:** PASS.

### 1.3 Memory Boundedness (Denial of Service)
- **Scenario:** Flooding the receiver with massive chunk streams to exhaust heap memory.
- **Defense Verification:** Chunks are read in 64 KiB chunks from the HTTP body into `raf.writeFrom` and `hasher.add`. The whole file is never loaded into RAM. The sender holds exactly one 4 MiB buffer in memory per in-flight upload.
- **Verdict:** PASS.

---

## 2. Conclusion

The Card A3 implementation is sound, strictly respects protocol security invariants, and introduces no vulnerability. Approved for application.
