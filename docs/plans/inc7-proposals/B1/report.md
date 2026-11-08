# Card B1 Report: Hotspot Candidate Lifecycle & Host Policy

## 1. Overview
Implements Card B1 from `inc7.md` (Increment 7 Wave B1):
- **Deterministic Host Election (`host_policy.dart`):** Implements all Design 03 Section 4.2 host selection rules:
  1. `canHost` capability gate (if only one side can host, that side hosts; if neither, returns null).
  2. `hostKeepsUplink` priority (if one device has `hostKeepsUplink=true`, it is elected host to avoid dropping its upstream internet connection).
  3. Platform ranking: `Android > Linux > Windows` (Android LocalOnlyHotspot preferred due to minimal disruption).
  4. Tie-breaker: If platforms are equal, the receiver hosts (receiver sets up hotspot so sender connects).
- **Headless In-Memory Hotspot Test Double (`fake_hotspot.dart`):**
  - `FakeAir`: Simulates the 802.11 Wi-Fi radio medium, tracking active SSIDs, credentials, and associated client interfaces.
  - `FakeHotspotBackend`: Provides hosting (`startHotspot`, `stopHotspot`) and client joining (`joinHotspot`, `disconnectFromHotspot`), validating WPA2/WPA3 PSKs and emitting disconnect events on simulated physical cuts.
- **Candidate Setup/Teardown Lifecycle (`http_connection.dart`):**
  - Calls `await candidate.setup().timeout(candidate.setupBudget)` before attempting TLS handshake.
  - Calls `await candidate.teardown()` on `close()` and on connection failure, ensuring zero orphaned hotspot networks or IP routes.

## 2. Test Verification
Executed in `.toolchain/scratch/inc7-b1/clone/`:
- `dart test packages/libreshare_core/test/unit/ble/b1_hotspot_policy_test.dart`
  - Cycle 1: 9 passed, 0 failed, 0 flakes (rc=0)
  - Cycle 2: 9 passed, 0 failed, 0 flakes (rc=0)
  - Cycle 3: 9 passed, 0 failed, 0 flakes (rc=0)
- `dart analyze packages/libreshare_core/lib/src/ble/host_policy.dart packages/libreshare_core/lib/src/ble/testing/fake_hotspot.dart packages/libreshare_core/test/unit/ble/b1_hotspot_policy_test.dart`
  - 0 issues found (rc=0)
- `dart format --output=none --set-exit-if-changed ...`
  - Formatted 3 files (0 changed) (rc=0)
