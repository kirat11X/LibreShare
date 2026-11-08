# Review: Increment 7 Card A3 (BLE Coordinator & Discovery Integration)

**Reviewer:** Review Agent (independent from author)  
**Date:** 2026-11-08  
**Scope:** `ble_coordinator.dart`, `device_discovery.dart`, `discovery_config.dart`, `libreshare_engine.dart`  
**Standard:** `docs/plans/REVIEW_STANDARD.md`

---

## 1. Hunk-by-Hunk Diff Read

| File / Component | Purpose | Concurrency & Lifecycle Analysis | Verdict |
|---|---|---|---|
| `ble_coordinator.dart` | Orchestrates BLE peripheral advertising and central scanning | Handles state transitions; clean cancellation of subscriptions | OK |
| `discovery_config.dart` | Config options for enabling/disabling BLE discovery | Pure configuration DTO; default disabled in headless/CI tests | OK |
| `device_discovery.dart` | Feeds BLE discovered peers into unified `PeerRegistry` | Marks discovery source as `CandidateKind.ble`; deduplicates by deviceId | OK |
| `libreshare_engine.dart` | Lifecycle hook to start/stop BLE coordinator with engine | Respects `ReceiveMode.off`; tears down cleanly on `engine.stop()` | OK |

---

## 2. Test Verification Against Specification

| Requirement | Test Assertion in `a3_coordinator_test.dart` | Result |
|---|---|---|
| Unified discovery includes BLE peers | Discovered BLE peer appears in `engine.devices` | PASS |
| Engine stop shuts down BLE coordinator | Coordinator disconnects and closes stream subscriptions | PASS |
| Receive Mode Off disables BLE advertising | Peripheral stops advertising when Receive mode changes to Off | PASS |

---

## 3. Mutation Testing Table

| Mutation Applied | Expected Behavior | Observed Result | Status |
|---|---|---|---|
| Omit BLE source in `device_discovery.dart` | BLE peers never registered | Caught: peer registry discovery test fails | **KILLED** |
| Do not call `coordinator.stop()` on engine stop | Stream controller leaks | Caught: leak detection assertion fails | **KILLED** |
| Ignore ReceiveMode updates in coordinator | Advertising remains active when Off | Caught: assertion expects inactive advert | **KILLED** |

---

## 4. Adversarial Edge Cases

1. **BLE Peer Flooding Registry:** Rate limiter caps new peer registrations to 20/sec.
2. **Duplicate Discovery Across LAN & BLE:** `PeerRegistry` merges records using unified `deviceId`.
3. **Rapid Engine Start/Stop:** Idempotent start and stop methods prevent double-close exceptions.
4. **Platform Radio Absence:** If BLE hardware is unsupported, coordinator logs warning and degrades gracefully.
5. **No Radio Commands Run:** Only in-process virtual fakes used; no system commands executed.

---

## 5. Verdict

**READY FOR INTEGRATION.** Meets all criteria in `docs/plans/REVIEW_STANDARD.md`.
