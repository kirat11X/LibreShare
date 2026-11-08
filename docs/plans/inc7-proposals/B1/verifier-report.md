# Card B1 Verifier Report: Mutation Analysis

## 1. Test Runs
- 3 consecutive runs of `dart test packages/libreshare_core/test/unit/ble/b1_hotspot_policy_test.dart`:
  - Run 1: 9 passed, 0 failed, rc=0
  - Run 2: 9 passed, 0 failed, rc=0
  - Run 3: 9 passed, 0 failed, rc=0
- Total flakes: 0.

## 2. Mutation Analysis

| Mutation ID | Target File & Line | Mutation Description | Expected Result | Actual Result | Status |
|-------------|-------------------|----------------------|-----------------|---------------|--------|
| **M1** | `host_policy.dart:28` | Invert `hostKeepsUplink` election priority | `hostKeepsUplink priority overrides platform ranking` fails (RED) | Test failed as expected | **KILLED** |
| **M2** | `host_policy.dart:45` | Invert platform tie-breaker (`!isReceiverA`) | `Platform tie-breaker selects the receiver` fails (RED) | Test failed as expected | **KILLED** |
| **M3** | `http_connection.dart:73` | Comment out `await candidate.teardown()` on close | `HotspotCandidate executes setup and asserts teardown on close` fails (RED) | Test failed as expected | **KILLED** |
| **M4** | `fake_hotspot.dart:98` | Remove PSK validation check in `joinHotspot` | `joinHotspot rejects incorrect PSK` fails (RED) | Test failed as expected | **KILLED** |

All 4 mutations killed cleanly by named test assertions.
Static analysis: 0 issues (rc=0).
Format: 0 changed (rc=0).
EOF
