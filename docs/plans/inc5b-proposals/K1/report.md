# Card K1 Report: `ip_classify`, `stun_client`, & `reachability_probe`

**Card:** K1 (Wave 1: IP Classification, STUN Discovery & Reachability Probe)  
**Author:** Lead  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 19/19 tests pass x3, 4/4 mutations killed)

---

## 1. Summary of Changes
Card K1 delivers the core network address classification and reachability components for Increment 5b:
1. **`packages/libreshare_core/lib/src/nat/ip_classify.dart` (Security-Critical)**:
   - Pure, table-driven IPv4 and IPv6 classifier without external syscall dependencies.
   - Accurately classifies: `loopback`, `privateIpv4` (RFC 1918), `cgnat` (RFC 6598 100.64.0.0/10), `linkLocal` (APIPA & fe80::/10), `multicast`, `ula` (RFC 4193 fc00::/7), `ipv4MappedIpv6` (::ffff:0:0/96), `globalUnicast` (2000::/3 and public IPv4), `reservedOrDoc`, and `invalid`.
   - Helper predicates: `isPublicRoutable()` and `isPrivateOrLocal()`.
2. **`packages/libreshare_core/lib/src/nat/stun_client.dart`**:
   - RFC 5389 compliant STUN client for discovering reflexive public addresses.
   - Builds 20-byte STUN Binding Requests with random 12-byte Transaction ID and Magic Cookie `0x2112A442`.
   - Parses XOR-MAPPED-ADDRESS (`0x0020`) and plain MAPPED-ADDRESS (`0x0001`).
   - Supports test socket injection for 100% hermetic unit testing without public internet dependencies.
3. **`packages/libreshare_core/lib/src/nat/reachability_probe_impl.dart`**:
   - Production implementation of `ReachabilityProbe` utilizing TCP connection probes with deadline timeouts.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze --fatal-infos` passed with 0 issues.
- **Code Formatting**: `dart format --output=none --set-exit-if-changed` verified clean.
- **Flake Gate**: 19/19 tests in `test/unit/nat/` passed across 3 consecutive runs.
- **Fuzz Testing**: 2,000 random mutations of IP literals verified to never throw unhandled exceptions.
- **Mutation Sweep**: 4/4 mutations killed (M1 CGNAT range check, M2 private IPv4 routability, M3 ULA mask, M4 STUN magic cookie validation).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for `ip_classify.dart`, `stun_client.dart`, `reachability_probe_impl.dart`.
- `test/unit/nat/ip_classify_test.dart`: Complete table-driven and fuzz test suite.
- `test/unit/nat/stun_client_test.dart`: STUN protocol and hermetic loopback mock tests.
- `test/unit/nat/reachability_probe_test.dart`: Probe tests against live loopback servers.
- `apply-notes.md`: Instructions for orchestrator application.
- `verifier-report.md`: Independent verifier sign-off.
