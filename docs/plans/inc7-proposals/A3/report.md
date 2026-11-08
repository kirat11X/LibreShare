# Card A3 Report: Increment 7 Wave A3 Engine Integration, Consent, Nearby List & Fast LAN Handoff

**Card:** A3 (Increment 7 Wave A3: Engine Integration, Consent, Nearby List & Fast LAN Handoff)  
**Author:** Lead / Orchestrator  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 8/8 tests pass x3, 4/4 mutations killed)

---

## 1. Summary of Changes
Card A3 integrates BLE discovery, GATT secure sessions, consent prompting, and fast LAN bypass into `LibreShareEngine`:

1. **`DiscoverySource.ble`**:
   - Added `ble` to `DiscoverySource` enum in `device_discovery.dart`.
   - Discovered BLE devices enter `PeerRegistry` tagged with `DiscoverySource.ble`.

2. **`ble_coordinator.dart`**:
   - `BleCoordinator`:
     - Advertises using `VisibilityManager` (contacts rotating EID or everyone random EID).
     - Scans for nearby LibreShare beacons (`companyId: 0xFFFF`, magic `LS`).
     - Resolves known contact EIDs using `matchesEid(contact.advKey, beacon.eid, now)` into pinned contact aliases; emits unpaired devices as anonymous nearby devices.
     - Handles incoming GATT sessions (Receiver/Peripheral role): performs mutual handshake, awaits `BleOffer`, dispatches `BleTransferPrompt` to application consent handler.
     - Enforces Rule R7 (No Auto-Accept without consent): unpaired transfers require SAS code confirmation and explicit user consent.
     - Rejection path: if receiver declines (`respond(false)`), sends `BleDecision(accept: false, reason: 'Declined by user')` and terminates the session with zero network or radio side effects.
     - Fast LAN bypass: when receiver accepts, Central evaluates peer's reported `lanCandidates`. If any candidate is reachable, emits `BleNetPlan(pathKind: 'lan')` and executes transfer over direct LAN without initiating a hotspot.
     - Hotspot handoff flag: if no LAN candidate is reachable, returns `BleRouteKind.hotspot` to trigger Phase B hotspot orchestration.

3. **`LibreShareEngine` & `DiscoveryConfig` Integration**:
   - `DiscoveryConfig` accepts `bleBackend`, `bleVisibility`, `advKey`, and `onBleTransferPrompt`.
   - `LibreShareEngine` instantiates and manages `BleCoordinator` lifecycle across `start()` and `stop()`, exposing `engine.bleCoordinator`.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze` passed with 0 issues.
- **Code Formatting**: `dart format` clean across all files.
- **Flake Gate**: 8/8 tests in `packages/libreshare_core/test/unit/ble/a3_engine_ble_test.dart` passed across 3 consecutive cycles.
- **Mutation Sweep (4/4 killed)**:
  - **M1 (Omit `DiscoverySource.ble` tag in registry)**: Discovery test fails -> **KILLED** (`M1_KILLED`).
  - **M2 (Bypass SAS verification check in `sendOffer`)**: SAS cancellation test fails -> **KILLED** (`M2_KILLED`).
  - **M3 (Invert consent decision in peripheral coordinator)**: Rejection test fails -> **KILLED** (`M3_KILLED`).
  - **M4 (Omit LAN candidate check in `sendOffer`)**: Fast LAN bypass test fails -> **KILLED** (`M4_KILLED`).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for `device_discovery.dart`, `ble_contracts.dart`, `ble_coordinator.dart`, `fake_ble_bus.dart`, `discovery_config.dart`, and `libreshare_engine.dart`.
- `test/a3_engine_ble_test.dart`: End-to-end multi-engine test suite over `FakeBleBus`.
- `apply-notes.md`: Instructions for orchestrator application.
- `verifier-report.md`: Independent verifier sign-off.
