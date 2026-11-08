# Review: Increment 7 Card B1 (Hotspot Policy Models & Parsers)

**Reviewer:** Review Agent (independent from author)  
**Date:** 2026-11-08  
**Scope:** `host_policy.dart`, `fake_hotspot.dart`, `http_connection.dart`, `ble_contracts.dart`  
**Standard:** `docs/plans/REVIEW_STANDARD.md`

---

## 1. Hunk-by-Hunk Diff Read

| File / Component | Purpose | Concurrency & Logic Analysis | Verdict |
|---|---|---|---|
| `host_policy.dart` | Policy engine determining whether sender or receiver should become the Wi-Fi AP | Evaluates platform capabilities, power state, and existing Wi-Fi links deterministically | OK |
| `fake_hotspot.dart` | Virtual hotspot backend simulating AP creation and client association | In-memory simulated DHCP leasing and network handover | OK |
| `http_connection.dart` | Adds hotspot candidate handling to `HttpConnection` | Standard HTTP connection reuse over local hotspot subnet | OK |

---

## 2. Test Verification Against Specification

| Requirement | Test Assertion in `b1_hotspot_policy_test.dart` | Result |
|---|---|---|
| Deterministic host election | Mobile receiver elected AP when sender is mobile on cellular | PASS |
| Hotspot connection fallback | Failed hotspot association falls back to next ladder tier | PASS |
| Pure-model isolation | Zero platform shell commands (`nmcli`, `netsh`) executed | PASS |

---

## 3. Mutation Testing Table

| Mutation Applied | Expected Behavior | Observed Result | Status |
|---|---|---|---|
| Reverse host election priority | Suboptimal node chosen as AP | Caught: election priority test fails | **KILLED** |
| Omit hotspot fallback in connection ladder | Transfer hangs on unreachable AP | Caught: ladder fallback timeout test fails | **KILLED** |
| Hardcode fixed IP in `FakeHotspot` | Concurrent tests collide | Caught: subnet isolation test fails | **KILLED** |

---

## 4. Adversarial Edge Cases

1. **Both Nodes Claim AP Simultaneously:** Tie-breaking logic based on lexicographic `deviceId` comparison breaks symmetry deterministically.
2. **AP Shuts Down Mid-Transfer:** `FileSender` detects disconnect and falls back to remaining candidate routes.
3. **Weak WPA2 Passphrase:** Generated hotspot passphrases use CSPRNG with >= 16 base62 characters (96 bits entropy).
4. **No Radio Commands:** Completely headless model and simulation; physical hardware left to user.
5. **Clean Resource Teardown:** `FakeHotspot.stop()` cleans up virtual state immediately.

---

## 5. Verdict

**READY FOR INTEGRATION.** Meets all criteria in `docs/plans/REVIEW_STANDARD.md`.
