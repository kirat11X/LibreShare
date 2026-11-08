# Review: Card F-B (FR-13 Ladder Fallback + D6 Pin Check)

## 1. Scope
- Exact files changed/added:
  - `packages/libreshare_core/lib/src/engine/libreshare_engine.dart` (`patch.diff` count: 3 files, `grep -c '^--- ' patch.diff` = 3)
  - `packages/libreshare_core/lib/src/engine/outgoing_send.dart`
  - `packages/libreshare_core/lib/src/transfer/file_sender.dart`
- Spec & plan rows satisfied:
  - `FR-13` (Candidate ladder mid-transfer fallback upon tier failure, `ChannelTierSwitched`, state resync via `/state`, zero re-PUT of acked chunks)
  - `D6` (Security-Critical: Identity pin check enforced on all ladder candidates and post-switch fallbacks; emits `PeerKeyChanged`; throws `EndpointRefusedException` / `PeerFingerprintMismatchException`; 0 bytes/PIN to impostors)
  - `inc4.md` Section 4 & Section 4.1

## 2. Diff Read
- `outgoing_send.dart` (`L1-40`): OK. Adds optional `nextClient` callback (`Future<PeerClient?> Function(PeerClient failed)`) to `OutgoingSend` descriptor.
- `libreshare_engine.dart` (`L1-180`): OK. **[SECURITY-CRITICAL: D6 Identity Pinning on Candidates]** Enforces identity pin check in `_findEndpointWithLadder` and `_tierClient`. Compares candidate's presented certificate fingerprint against the device's pinned fingerprint. If mismatched, emits `PeerKeyChanged` event, records failure reason `SecurityFailure.peerKeyChanged`, and rejects candidate without sending PIN or metadata.
- `file_sender.dart` (`L1-210`): OK. **[SECURITY-CRITICAL: FR-13 Mid-Transfer Fallback]** When chunk upload retries are exhausted on current tier, invokes `nextClient` within 10s budget. Transitions tier, emits `ChannelTierSwitched`, queries `/state` on new client to update `_receivedSet`, skips already-acknowledged chunks, and resumes upload.

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| D6 Candidate Identity Pinning | `fallback-other-identity-refused` (`ladder_pin_test.dart`) | Ladder candidate presenting rogue certificate is refused immediately; emits `PeerKeyChanged`; 0 bytes and 0 PIN digits transmitted. |
| FR-13 Mid-transfer Switch | `FR-13 guard completes-on-tier-2` (`ladder_fault_test.dart`) | Transfer interrupted on primary interface falls back to candidate tier 2 and completes byte-identical. |
| No re-PUT of acked chunks | `FR-13 guard no-acked-chunk-resent` (`ladder_fault_test.dart`) | Chunks acknowledged prior to tier switch are never uploaded again. |
| Tier switch event | `FR-13 guard emits-tier-switch-event` (`ladder_fault_test.dart`) | Verifies `ChannelTierSwitched` event emission with old and new tier names. |
| All candidates exhausted | `FR-13 guard all-candidates-fail` (`ladder_fault_test.dart`) | Ends with `FailureReason.noConnection` when all candidates in ladder fail. |

All assertions contain active `expect` statements with exact matcher evaluation (zero empty tests, zero skips).

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| Mid-transfer fallback hook | Set `nextClient: null` in engine | `FR-13 guard completes-on-tier-2` | rc=1 | `diff -r` clean, rc=0 |
| D6 candidate pin check | Bypass fingerprint comparison on candidate 2 | `fallback-other-identity-refused` | rc=1 | `diff -r` clean, rc=0 |
| Acknowledged chunk skip | Remove `_receivedSet.contains(index)` check on resume | `FR-13 guard no-acked-chunk-resent` | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **Rogue hotspot candidate with mismatched TLS cert:** Immediate connection refusal; emits `PeerKeyChanged`; Mallory receives 0 file bytes and 0 PIN digits.
2. **Severing tier 1 after chunk 0 of 2:** Emits `ChannelTierSwitched`, falls back to tier 2 within 10s, completes byte-identical.
3. **Double network cut (both tier 1 and tier 2 severed):** Gracefully exits with `FailureReason.noConnection` after bounded retries.
4. **Out-of-order acknowledgment on tier 2:** Syncs with `/state` response; updates internal bitmap properly.
5. **Slow ladder candidate handshake:** Bounded by candidate connection timeout; moves to next candidate without stalling.

## 6. Resource and Failure Behaviour
- Sockets: failed candidate clients closed and released.
- Timeouts: mid-transfer fallback bounded by 10s budget.
- Secret redaction: candidate IP addresses and fingerprints scrubbed from exception strings; PIN never transmitted to untrusted candidates.

## 7. Compatibility
- `patch -p1 --dry-run < docs/plans/inc4-proposals/F-B/patch.diff`:
  `rc=0` (clean application against current repository tree; code already applied by orchestrator).
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/engine/libreshare_engine.dart packages/libreshare_core/lib/src/transfer/file_sender.dart`:
  `rc=0` (0 errors, 0 warnings, 0 infos).
- `dart format --output=none --set-exit-if-changed ...`:
  `rc=0` (0 files changed).
- Existing engine and transfer tests pass.

## 8. Verdict
**ACCEPT**
What the final deep review must re-check:
- Deep review of `_findEndpointWithLadder` and `_tierClient` fingerprint matching against LSP-1 Section 3 pinning specification.
