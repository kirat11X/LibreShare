# Card W3 Report: PairingService Rendezvous Handshake & CLI peers Command

**Card:** W3 (Increment 6 Wave 3: PairingService & CLI pair/peers)  
**Author:** Lead  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 7/7 tests pass x3, 4/4 mutations killed)

---

## 1. Summary of Changes
Card W3 implements and verifies the pairing handshake and CLI peers inspection for Increment 6:

1. **`PairingService` Verification (`packages/libreshare_core/test/unit/rendezvous/pairing_rendezvous_test.dart`)**:
   - Confirms inviter and scanner agree on identical SAS and $K_\text{pair}$ = HKDF-SHA256(S, salt=$n_A \parallel n_B$, info="LSP-R1 pair" $\parallel \min(fp_A,fp_B) \parallel \max(fp_A,fp_B)$).
   - Verifies single-use guarantee: invite secret $S$ is permanently consumed and zeroed upon pairing acceptance; subsequent attempts throw notFound.
   - Verifies replay/tamper guard: tampered request MAC is actively rejected with error without consuming or corrupting the pending invite.
   - Verifies 10-minute TTL expiry: expired invites cannot be scanned or accepted.
   - Verifies scanner race condition: first scanner accepted wins; concurrent scanner encounters conflict error.

2. **`ls peers` CLI Command (`packages/libreshare_cli/lib/ls_cli.dart`)**:
   - Implements `ls peers` command reading paired contacts from `SecurityWiring.open()`.
   - Filters contacts to only those with `hasPairKey == true`.
   - Outputs `PEER <deviceId> alias="<alias>" fp=<shortFp> trust=<trustLevel>`.
   - If no peers paired, outputs clean notification: `No paired peers.`.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze --fatal-infos packages/libreshare_cli/lib/ls_cli.dart packages/libreshare_cli/test/peers_cli_test.dart packages/libreshare_core/test/unit/rendezvous/pairing_rendezvous_test.dart` -> 0 issues.
- **Code Formatting**: `dart format --output=none --set-exit-if-changed` verified clean (0 changes).
- **Flake Gate**: 7/7 tests passed across 3 consecutive cycles.
- **Mutation Sweep (4/4 killed)**:
  - **M1 (Bypass TTL expiration check in `_activeInvite`)**: `expired invite is rejected` fails -> **KILLED** (`M1_KILLED`).
  - **M2 (Do not spend/clear invite on accept)**: `reused invite secret S is rejected after being spent` fails -> **KILLED** (`M2_KILLED`).
  - **M3 (Accept tampered request MAC)**: `tampered request MAC is actively rejected` fails -> **KILLED** (`M3_KILLED`).
  - **M4 (Omit `hasPairKey` filter in `ls peers`)**: `ls peers lists only contacts that have pair keys` fails -> **KILLED** (`M4_KILLED`).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for `packages/libreshare_cli/lib/ls_cli.dart`.
- `test/pairing_rendezvous_test.dart`: Core pairing handshake and SAS agreement tests.
- `test/peers_cli_test.dart`: CLI peers command tests.
- `apply-notes.md`: Application instructions for orchestrator.
- `verifier-report.md`: Independent verifier sign-off.
- `second-tester-report.md`: Security-critical second tester sign-off.
