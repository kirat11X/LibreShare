# Card K0 Report: Increment 5b Wave 0 Contracts & Protocols

**Card:** K0 (Wave 0 Seams, Data Models & Schema Updates)  
**Author:** Lead  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 4/4 tests pass x3, 3/3 mutations killed)

---

## 1. Summary of Changes
Card K0 provides the architectural foundation and contracts for Increment 5b (IPv6, UPnP/NAT-PMP/PCP, Hide My IP):
1. **`docs/plans/inc5b-seams.md`**:
   - Comprehensive documentation of all Wave 0 signatures, models, and protocol extensions.
2. **`docs/protocol/schemas/tunnel-offer.schema.json`**:
   - Added optional `candidates` array (up to 4 candidate specs) and `pin` (ephemeral TLS cert SHA-256 fingerprint).
3. **Core Data Models (`packages/libreshare_core/lib/src/nat/`)**:
   - `origin_kind.dart`: `OriginKind` enum with wire parsing and priority ordering (`directIpv6` > `mappedIpv4` > `tunnelCloudflare` > `tunnelZrok` > `manual`).
   - `port_mapping.dart`: `PortMapping` and `PortMappingProtocol` immutable models with lease calculation and expiry checking.
   - `gateway_info.dart`: `GatewayInfo` and `GatewayProtocol` router descriptor models.
   - `port_mapper.dart`: `PortMapper` abstract interface for discovering routers, requesting/releasing mappings, and sweeping stale records.
   - `reachability_probe.dart`: `ReachabilityProbe` interface for direct network path verification.
4. **Unit Contract Tests (`packages/libreshare_core/test/unit/nat/contract_test.dart`)**:
   - 4 tests covering wire conversions, priority hierarchies, expiry mechanics, and interface implementation fidelity.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze --fatal-infos` passed with 0 issues.
- **Code Formatting**: `dart format --output=none --set-exit-if-changed` verified clean (0 files changed).
- **Flake Gate**: 4/4 tests passed 3 consecutive runs with 0 failures or flakes.
- **Mutation Sweep**: 3/3 mutations killed (M1 priority inversion, M2 expiry corruption, M3 equality corruption).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for contracts and schemas.
- `test/unit/nat/contract_test.dart`: Complete unit test file.
- `apply-notes.md`: Instructions for orchestrator application.
- `verifier-report.md`: Independent verifier sign-off.
