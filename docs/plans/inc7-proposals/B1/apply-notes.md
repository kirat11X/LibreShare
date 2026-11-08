# Apply Notes: Card B1 (Hotspot Candidate Lifecycle & Host Policy)

## Files Touched
The patch modifies/creates 4 files:
- `packages/libreshare_core/lib/src/ble/host_policy.dart`: Deterministic host election implementing Design 03 Section 4.2 (`canHost`, `hostKeepsUplink`, 3x3 platform matrix, receiver tie-breaker).
- `packages/libreshare_core/lib/src/ble/testing/fake_hotspot.dart`: Headless simulation test harness (`FakeAir`, `FakeHotspotBackend`, PSK verification, disconnect notifications, link degradation).
- `packages/libreshare_core/lib/src/connection/http_connection.dart`: Invokes `candidate.setup()` on connection open and guarantees `candidate.teardown()` on close/error without orphaned Wi-Fi configurations.
- `packages/libreshare_core/lib/src/ble/ble_contracts.dart`: Exports `host_policy.dart` and `fake_hotspot.dart`.

## Unit Test File
- `packages/libreshare_core/test/unit/ble/b1_hotspot_policy_test.dart` (installed in `test/` of this proposal).

## Application Command
```bash
patch -p0 < docs/plans/inc7-proposals/B1/patch.diff
cp docs/plans/inc7-proposals/B1/test/b1_hotspot_policy_test.dart packages/libreshare_core/test/unit/ble/
```
