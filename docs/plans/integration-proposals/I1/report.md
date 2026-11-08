# Integration Card I1 Report: Cross-Increment Integration Suite

## Summary
Card I1 delivers the comprehensive cross-increment integration test suite validating subsystems across Increments 1 through 7 working together in harmony:
1. `i1_link_share_e2e_test.dart`: End-to-end link share over `FakeTunnelProvider` -> `TunnelOriginServer` -> `ShareLink` -> chunk pulling, byte-identical verification, zero secret/key fragment logging, and adversarial corruptions.
2. `i1_nat_ladder_integration_test.dart`: In-process gateway responders (`FakeIgdGateway`, `FakePcpServer` for NAT-PMP and PCP) on ephemeral OS ports, `UnifiedPortMapper` port leases, `CandidateRace` origin prioritization and automatic fallback when mapped ports are dead, plus `DirectConnection` SHA-256 TLS cert pinning.
3. `i1_rendezvous_integration_test.dart`: In-process rendezvous layer over `InMemoryRelay` and `PairingService` SAS agreement -> mutual `K_pair` derivation -> encrypted `OfferRecord` exchange -> sealed decision ack verification -> anti-replay timestamp/sequence validation -> multi-relay failover.
4. `i1_ble_hotspot_policy_integration_test.dart`: BLE / Hotspot policy models (`chooseHost` platform matrix, uplink preservation rule, receiver tie-breaker), `FakeAir` radio medium simulation, `HotspotCandidate` setup/teardown lifecycle, and `ConnectionManager` tier switching from severed hotspot to fallback Wi-Fi.
5. `i1_cross_increment_regression_test.dart`: Cross-increment regression validating Inc 1-4 core invariants: `SpeedMode` (eco=1, balanced=3, turbo=8), `PinGuard` brute force lockout (5 failed attempts block 6th even with correct PIN), D6 PIN identity check on ladder candidates, FR-13 fallback, and partial session resumption bitmask adoption.

## Test Results
- Suite 1 (`i1_link_share_e2e_test.dart`): 5/5 passed (0 flakes in 3x runs)
- Suite 2 (`i1_nat_ladder_integration_test.dart`): 4/4 passed (0 flakes in 3x runs)
- Suite 3 (`i1_rendezvous_integration_test.dart`): 5/5 passed (0 flakes in 3x runs)
- Suite 4 (`i1_ble_hotspot_policy_integration_test.dart`): 4/4 passed (0 flakes in 3x runs)
- Suite 5 (`i1_cross_increment_regression_test.dart`): 5/5 passed (0 flakes in 3x runs)
- **Total:** 23/23 tests passed in 1.4s under heavy lock.
- **Flake verification:** 3 consecutive runs (3x 23/23 = 69 runs), 0 failures.
- **Static Analysis:** `dart analyze packages/libreshare_core/test/integration/i1_*` reports 0 issues.
- **Formatting:** `dart format --set-exit-if-changed` reports 0 changed files.

## Mutations Evaluated
- Mutation 1: Corrupted assembled file bytes check in `i1_link_share_e2e_test.dart` -> KILLED.
- Mutation 2: Inverted `chooseHost` tie-breaker rule in `i1_ble_hotspot_policy_integration_test.dart` -> KILLED.
- Mutation 3: Inverted lockout threshold in `i1_cross_increment_regression_test.dart` -> KILLED.
- Mutation 4: Inverted NAT origin priority in `CandidateRace` in `i1_nat_ladder_integration_test.dart` -> KILLED.
