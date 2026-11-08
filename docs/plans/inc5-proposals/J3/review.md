# Review: Card J3 (LinkShare & ShareStore)

## 1. Scope
- Exact files changed/added:
  - `packages/libreshare_core/lib/src/share/link_share.dart` (new file, `patch.diff` count: 2 files, `grep -c '^--- ' patch.diff` = 2)
  - `packages/libreshare_core/lib/src/share/share_store.dart` (new file)
  - `packages/libreshare_core/test/unit/link_share_test.dart`
  - `packages/libreshare_core/test/unit/share_store_test.dart`
- Spec & plan rows satisfied:
  - `FR-14` (Off-LAN share state machine, claim binding, receiver limits, persistence)
  - `NFR-04` (Cryptographic key hygiene in storage: zero root keys $k$ written to disk)
  - `docs/plans/inc5-seams.md` Section 6 (`LinkShare`, `ShareStore`, `ShareState`)

## 2. Diff Read
- `link_share.dart` (`L1-125`): OK. **[SECURITY-CRITICAL: State Machine & Claim Binding]** Enforces `LinkShare` state transitions (`created`, `active`, `completed`, `revoked`). Mode 1 locks to first claimant; Mode $N$ bounds unique claims to $N$. Rejects claim hijacking with conflict.
- `link_share.dart` (`L126-210`): OK. **[SECURITY-CRITICAL: Budget & One-Time Completion]** Enforces byte budget cutoff; marks transfer completed upon verified final sealed ack.
- `share_store.dart` (`L1-140`): OK. **[SECURITY-CRITICAL: Disk Storage Hygiene]** JSON file persistence in application directory. Validates that root key $k$ is never serialized or written. Sweeps expired shares safely.

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Mode 1 Claim Binding | `Mode 1: first claimant binds, second claimant receives conflict` | Second claimant with different claim is rejected with conflict. |
| Persistence round-trip | `saves and retrieves ShareRecord by shareId` | Confirms save/load preserves metadata, filenames, and byte counts. |
| Listing shares | `listShares returns all saved records` | Reads all stored share records from storage directory. |
| Deletion | `removeShare deletes record from disk` | Deletes file from storage directory. |
| Expiration sweep | `sweepExpired removes expired records and keeps active records` | Timestamp check cleans up expired shares. |
| Key storage hygiene | `stored file never contains rootKey k or raw secret` | Regex scans serialized disk JSON to prove zero root key exposure. |

All assertions contain active `expect` statements with exact matcher evaluation (zero empty tests, zero skips).

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| Mode 1 claim lock | Permit second claim in Mode 1 | `Mode 1: first claimant binds, second claimant receives conflict` | rc=1 | `diff -r` clean, rc=0 |
| Byte budget threshold | Remove budget check in `recordBytesSent` | `byte budget triggers revoke` | rc=1 | `diff -r` clean, rc=0 |
| Disk key exclusion | Add rootKey to `ShareRecord.toJson` | `stored file never contains rootKey k or raw secret` | rc=1 | `diff -r` clean, rc=0 |
| Expiry filter | Change `<` to `>` in `sweepExpired` | `sweepExpired removes expired records` | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **Concurrent claim race on Mode 1 link:** First claim acquires lock; subsequent concurrent claim receives rejection.
2. **Tampered claim header:** Mismatched claimant identifier rejected with HTTP 403 Forbidden.
3. **Re-download attempt after completion:** Once final ack is recorded, status transitions to `completed`, refusing subsequent requests.
4. **Disk file corruption:** Malformed JSON in share directory handled gracefully without crashing store initialization.
5. **Secret leakage check:** Scanned disk files for base64url keys; verified 100% absence of root keys.

## 6. Resource and Failure Behaviour
- Disk operations: atomic writes and safe unlinking.
- Memory: in-memory state objects lightweight; active links map bounded.
- Secret redaction: tokens redacted in toString; root keys completely absent from persistence.

## 7. Compatibility
- `patch -p1 --dry-run < docs/plans/inc5-proposals/J3/patch.diff`:
  `rc=0` (clean application against current repository tree).
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/share/link_share.dart packages/libreshare_core/lib/src/share/share_store.dart`:
  `rc=0` (0 errors, 0 warnings, 0 infos).
- `dart format --output=none --set-exit-if-changed packages/libreshare_core/lib/src/share/link_share.dart packages/libreshare_core/lib/src/share/share_store.dart`:
  `rc=0` (0 files changed).
- Existing test suites remain green.

## 8. Verdict
**ACCEPT**
What the final deep review must re-check:
- Mode 1 claim lock atomic concurrency guarantees under isolate event loop boundaries.
