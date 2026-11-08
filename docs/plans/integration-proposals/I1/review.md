# Review: Card I1 (Cross-Increment Integration Suite)

## 1. Hunk-by-Hunk Diff Read
- `packages/libreshare_core/test/integration/i1_link_share_e2e_test.dart`:
  - Instantiates `TunnelOriginServer` on port 0 and attaches `FakeTunnelProvider`.
  - Sets up multi-chunk sealed manifest and chunk endpoints.
  - Generates `ShareLink` with secret fragment `#...`.
  - Audits log stream to prove key fragment and raw root key never appear in any log or event.
  - Tests bit-flip MAC corruption, wrong root key, 409 multi-claimant conflict, and expired link detection.
- `packages/libreshare_core/test/integration/i1_nat_ladder_integration_test.dart`:
  - Starts `FakeIgdGateway` (UPnP IGD) and `FakePcpServer` (NAT-PMP / PCP) on ephemeral ports.
  - Verifies port mapping acquisition and deletion via `UnifiedPortMapper` and direct protocol clients.
  - Tests `CandidateRace` prioritizing mapped IPv4 over tunnel candidates, gracefully falling back to tunnel when mapped candidate fails.
  - Tests `DirectConnection` SHA-256 certificate pinning and `OriginCandidateSpec` validation.
- `packages/libreshare_core/test/integration/i1_rendezvous_integration_test.dart`:
  - Verifies `PairingService` mutual handshake, SAS agreement, and identical `K_pair` derivation.
  - Verifies `RendezvousServiceImpl` offer exchange over `InMemoryRelay` and sealed decision ack.
  - Verifies `ReplayGuard` enforcing monotonic sequences and duplicate offer detection.
  - Verifies `EnvelopeCodecImpl` 512-byte discrete bucket padding and ciphertext tampering rejection.
  - Verifies multi-relay failover when primary relay drops.
- `packages/libreshare_core/test/integration/i1_ble_hotspot_policy_integration_test.dart`:
  - Verifies `chooseHost` platform ranking, uplink preservation, and receiver tie-breaker.
  - Tests `FakeAir` radio medium, join PSK validation, and radio cut simulation.
  - Tests `HotspotCandidate` setup/teardown lifecycle asserting zero orphan state.
  - Tests `ConnectionManager` falling back from severed hotspot to Wi-Fi candidate.
- `packages/libreshare_core/test/integration/i1_cross_increment_regression_test.dart`:
  - Validates `SpeedMode` concurrency mapping (eco=1, balanced=3, turbo=8) and name aliases.
  - Validates `PinGuard` brute force lockout policy (5 wrong strikes lock out 6th attempt even with correct PIN).
  - Validates candidate fingerprint check (D6).
  - Validates FR-13 candidate fallback.
  - Validates resumption bitmask adoption.

## 2. Test Verification Against Specifications
| Test Case | Spec Requirement | Verified Behavior | Status |
| :--- | :--- | :--- | :--- |
| `i1_link_share_e2e_test` | I1(a) Link share end-to-end | `FakeTunnelProvider` -> `ShareLink` -> download -> byte identical | PASS |
| `i1_link_share_e2e_test` (secret hygiene) | I1(a) Secret redaction | URL key fragment / root key never logged in events or logs | PASS |
| `i1_nat_ladder_integration_test` | I1(b) Fake gateway responders | UPnP IGD, NAT-PMP, and PCP produce origin candidates | PASS |
| `i1_nat_ladder_integration_test` (fallback) | I1(b) Ladder fallback | Dead mapped port falls back to healthy tunnel candidate | PASS |
| `i1_rendezvous_integration_test` | I1(c) Rendezvous & SAS | `PairingService` SAS -> `RendezvousService` offer -> sealed ack | PASS |
| `i1_rendezvous_integration_test` (tamper) | I1(c) Replay & forgery defense | Tampered envelope ciphertext and replayed sequences rejected | PASS |
| `i1_rendezvous_integration_test` (failover)| I1(c) Multi-relay failover | Disconnected primary relay fails over to secondary relay | PASS |
| `i1_ble_hotspot_policy_integration_test` | I1(d) BLE / Hotspot policy | `chooseHost` matrix, uplink override, receiver tie-breaker | PASS |
| `i1_ble_hotspot_policy_integration_test` | I1(d) Hotspot lifecycle | Setup on connect, guaranteed teardown on disconnect | PASS |
| `i1_cross_increment_regression_test` | I1(e) Inc 1-4 regressions | Resumption, FR-13, D6 PIN, Speed modes, PIN lockout | PASS |

## 3. Mutation Testing
| Mutation | Target File / Line | Expected Result | Actual Result |
| :--- | :--- | :--- | :--- |
| M1: Corrupt assembled file check | `i1_link_share_e2e_test.dart:148` | Test fails on corrupted bytes | KILLED (RED) |
| M2: Invert `chooseHost` tie-breaker | `i1_ble_hotspot_policy_integration_test.dart:61` | Test fails on wrong host winner | KILLED (RED) |
| M3: Invert PIN lockout strike count | `i1_cross_increment_regression_test.dart:96` | Test fails on unblocked 6th attempt | KILLED (RED) |
| M4: Invert NAT origin priority order | `i1_nat_ladder_integration_test.dart:155` | Test fails on inverted priority | KILLED (RED) |

## 4. Adversarial Edge Cases Tested
1. **Ciphertext bit-flip tampering:** Tested in `i1_link_share_e2e_test.dart` and `i1_rendezvous_integration_test.dart`; AES-GCM MAC validation failure prevents unauthenticated data delivery.
2. **Key mismatch:** Receiver using an unauthenticated/wrong root key fails unsealing immediately without exposing plaintext.
3. **Multi-claimant race (Mode 1):** First claimant binds successfully; second intruder claimant receives HTTP 409 Conflict.
4. **Link expiration enforcement:** Expired link is detected and bad expiry timestamps are rejected by `ShareLink.parse`.
5. **SSRF / IP literal guard:** Private/loopback hosts in share links are rejected unless developer flags are explicitly granted.
6. **PIN brute-force lockout:** 5 consecutive invalid PIN attempts trigger exponential/10-minute lockout where even the valid PIN is blocked.
7. **Certificate fingerprint mismatch (D6):** Candidate presenting an unpinned certificate is refused prior to chunk transfer.

## 5. Leaked Resources & Secrets Check
- All HTTP servers (`TunnelOriginServer`, `FakeIgdGateway`) bind to OS-picked port 0 and are explicitly stopped in `tearDown`.
- All UDP sockets (`FakePcpServer`) bind to port 0 and are closed in `tearDown`.
- All `FakeHotspotBackend` reservations and joins are cleanly terminated.
- Zero secret strings (PINs, SAS codes, tunnel keys, BIP-340 private keys) appear in logs or test output.

## 6. Verdict
**PASS / READY.** All 23 integration tests pass 100% green with 0 flakes across 3 consecutive runs under heavy lock. Zero analyzer warnings or formatting violations.
