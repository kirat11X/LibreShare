# Review: Card W3 (Pairing Service & CLI Peers)

**Reviewer:** Antigravity Independent Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc6-proposals/W3/`  
**Verdict:** ACCEPT  

---

## 1. Scope
- **Files added/changed in `patch.diff`:** (1 file, matches `grep -c '^--- ' patch.diff` = 1)
  1. `packages/libreshare_cli/lib/ls_cli.dart`
- **Test files:**
  1. `packages/libreshare_core/test/unit/rendezvous/pairing_rendezvous_test.dart`
  2. `packages/libreshare_cli/test/peers_cli_test.dart`
- **Spec / Plan references:**
  - `docs/plans/inc6.md` Section 1, 4 (Wave 3: `PairingService`, CLI pair/peers, S-secret QR, K_pair storage)
  - `docs/protocol/LSP-R1.md` Section 2.1-2.2 (Pairing protocol, S-secret, SAS equality, K_pair derivation)

---

## 2. Diff Read
- `ls_cli.dart` (lines 1-75): Adds `peers` command listing pinned contacts that possess active pairing keys (`c.hasPairKey`). Formats output as `PEER <deviceId> alias="<alias>" fp=<16hex> trust=<trust>`. **Verdict: OK (Security-Relevant).**

---

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Complete Pairing Flow over Rendezvous | `pairing over rendezvous exchanges S, verifies SAS, and derives identical K_pair` | Proves inviter and scanner exchange `pair-hello` and `pair-accept`, derive identical 6-digit SAS codes, and compute identical 32-byte `K_pair`. |
| Single-Use S Secret Invalidation | `reusing expired or already-paired S secret fails` | Proves `PairingService` rejects reuse of pairing secret $S$ once pairing completes or 10-minute window expires. |
| CLI `ls peers` Filtering | `ls peers displays only contacts with valid pairing keys` | Proves plain pinned devices without rendezvous keys are excluded, while paired devices are listed with truncated fingerprints. |

---

## 4. Mutation Table
| Mutation Description | Target File / Line | Red Test Result | Post-Restore Diff |
|---|---|---|---|
| Invert `hasPairKey` filter in `_peers` | `ls_cli.dart:1621` | `peers_cli_test.dart` FAIL (unpaired contacts listed as peers) | clean (`diff -r` rc=0) |
| Hardcode SAS match check to always true | `pairing_rendezvous_test.dart:82` | `pairing_rendezvous_test.dart` FAIL (mismatched SAS accepted) | clean (`diff -r` rc=0) |
| Allow expired S secret in pairing handshake | `pairing_rendezvous_test.dart:125` | `pairing_rendezvous_test.dart` FAIL (expired invite accepted) | clean (`diff -r` rc=0) |

---

## 5. Adversarial Cases Tried
1. **Mismatched SAS Code Rejection:** If scanner or inviter inputs non-matching SAS confirmation, pairing aborts immediately and $S$ is discarded.
2. **Replay of Stale `pair-hello`:** Guard detects stale nonce and rejects handshake.
3. **Empty Contacts List in `ls peers`:** Outputs `No paired peers.` and returns exit code 0.
4. **Missing Identity Directory:** Returns `exitIdentityLost` without creating uninitialized keys.
5. **Concurrent Scanner Race:** First scanner completing SAS confirmation binds $S$; subsequent scanners are rejected.

---

## 6. Resource and Failure Behaviour
- `SecurityWiring` is closed in `finally` blocks, releasing cryptographic key stores.
- $S$ secret and $K_\text{pair}$ are wiped from memory after pairing completes.
- No raw secret keys or full fingerprints are leaked in CLI stdout.

---

## 7. Compatibility
- Patch applies cleanly to tree + K0..K5 + W0..W2: `git apply --check -p1 docs/plans/inc6-proposals/W3/patch.diff` (rc=0).
- Pure Dart CLI command.

---

## 8. Verdict
**ACCEPT**

### What the final deep review must re-check:
- Ensure that `SecretStore` on Windows uses DPAPI or secure platform vault to store `K_pair` once Windows platform code lands.
