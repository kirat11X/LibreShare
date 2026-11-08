# Card W0 Report: Increment 7 Wave 0 Contracts, Schemas & Protocols

**Card:** W0 (Increment 7 Wave 0: BLE & Hotspot Contracts, Protocol Schemas, inc7-seams.md)  
**Author:** Lead / Orchestrator  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 16/16 tests pass x3, 4/4 mutations killed)

---

## 1. Summary of Changes
Card W0 establishes the foundational architectural contracts, protocol schemas, and interface definitions for Increment 7 ("LS-BLE/1" BLE Discovery & Hotspot Handoff):

1. **`docs/plans/inc7-seams.md`**:
   - Outlines integration seams with `PeerRegistry` (BLE discovery tag), `TrustStore` (storage of `peerAdvKey` for rotating EID verification), GATT secure channel state machine, and `ConnectionManager`.
   - Codifies Rule: receiver consent precedes any hotspot activation or network disruption; files always move over LSP/1 on an IP path.
   - Defines fast LAN bypass when both devices are on the same Wi-Fi router.

2. **JSON Schemas (`docs/protocol/ble/schemas/`)**:
   - `ble-m1.schema.json`: Central to Peripheral initial key exchange.
   - `ble-m2.schema.json`: Peripheral to Central response.
   - `ble-auth.schema.json`: Encrypted identity verification and LAN candidate exchange.
   - `ble-offer.schema.json`: Transfer metadata offer over GATT.
   - `ble-decision.schema.json`: Receiver consent decision (accept/reject).
   - `ble-netplan.schema.json`: Role and path assignment plan.
   - `ble-hotspot.schema.json`: Encrypted hotspot credentials and endpoints.
   - `ble-joined.schema.json`: Joiner confirmation.

3. **Core Interface Contracts (`packages/libreshare_core/lib/src/ble/`)**:
   - `beacon_types.dart`: `BleBeacon`, `BeaconFlags`, `BeaconCap`, and `BlePlatform` binary encoding/decoding.
   - `ble_messages.dart`: Sealed `BleMessage` hierarchy with JSON serialization/deserialization.
   - `ble_backend.dart`: Abstraction for platform BLE advertisers, scanners, GATT servers, and sessions.
   - `hotspot_backend.dart`: Abstraction for Wi-Fi hotspot creation and association.
   - `candidate.dart`: Added `CandidateKind.hotspot`, `setupBudget` (90s for join, 10s for host), `connectBudget`, `setup()`, `teardown()`, and `HotspotCandidate`.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze` passed with 0 issues.
- **Code Formatting**: `dart format` clean across all files.
- **Flake Gate**: 16/16 tests in `packages/libreshare_core/test/unit/ble/` passed across 3 consecutive cycles without flakes.
- **Mutation Sweep (4/4 killed)**:
  - **M1 (Corrupt beacon length/magic check)**: Fails beacon binary validation -> **KILLED** (`M1_KILLED`).
  - **M2 (Corrupt BleM1 message discriminator)**: Fails schema validation -> **KILLED** (`M2_KILLED`).
  - **M3 (Invert HotspotRole setupBudget)**: Fails candidate setupBudget assertion -> **KILLED** (`M3_KILLED`).
  - **M4 (Omit required schema fields)**: Schema negative controls fail validation -> **KILLED** (`M4_KILLED`).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for `inc7-seams.md`, schemas, `ble/` interfaces, and `candidate.dart`.
- `test/contracts_test.dart`: Unit tests for beacon binary serialization, messages, and candidate hooks.
- `test/schema_test.dart`: JSON Schema validation and negative control suite.
- `apply-notes.md`: Instructions for orchestrator application.
- `verifier-report.md`: Independent verifier sign-off.
