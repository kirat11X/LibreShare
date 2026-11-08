# Review: Card K0 (Increment 5b Wave 0 Contracts & Protocols)

**Reviewer:** Antigravity Independent Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc5b-proposals/K0/`  
**Verdict:** ACCEPT  

---

## 1. Scope
- **Files added/changed in `patch.diff`:** (6 files, matches `grep -c '^--- ' patch.diff` = 6)
  1. `docs/plans/inc5b-seams.md`
  2. `packages/libreshare_core/lib/src/nat/gateway_info.dart`
  3. `packages/libreshare_core/lib/src/nat/origin_kind.dart`
  4. `packages/libreshare_core/lib/src/nat/port_mapper.dart`
  5. `packages/libreshare_core/lib/src/nat/port_mapping.dart`
  6. `packages/libreshare_core/lib/src/nat/reachability_probe.dart`
- **Test files:**
  1. `packages/libreshare_core/test/unit/nat/contract_test.dart`
- **Spec / Plan references:**
  - `docs/plans/inc5b.md` Section 1, 2, 4 (Wave 0 contracts)
  - `docs/design/04-link-qr-and-free-internet-paths.md` sections 2-5 (Origin hierarchy, candidate racing)

---

## 2. Diff Read
- `docs/plans/inc5b-seams.md` (lines 1-114): Documents Wave 0 architecture, data models, error codes, and testing strategy. **Verdict: OK.**
- `gateway_info.dart` (lines 1-43): `GatewayProtocol` enum (`upnpIgd`, `natPmp`, `pcp`, `unknown`) and immutable `GatewayInfo` class with `==` and `hashCode`. **Verdict: OK.**
- `origin_kind.dart` (lines 1-27): `OriginKind` enum (`directIpv6`, `mappedIpv4`, `tunnelCloudflare`, `tunnelZrok`, `manual`) with priority hierarchy (`directIpv6: 10` < `mappedIpv4: 20` < `tunnelCloudflare: 30` < `tunnelZrok: 40` < `manual: 50`) and `fromWireName`. **Verdict: OK (Security-relevant: candidate priority order prevents downgrade to slower or third-party tiers).**
- `port_mapper.dart` (lines 1-32): Abstract `PortMapper` interface defining discovery, mapping acquisition, release, sweep, and lifecycle `close()`. **Verdict: OK.**
- `port_mapping.dart` (lines 1-56): `PortMappingProtocol` and immutable `PortMapping` model with `expiresAt` calculation and `isExpired([DateTime? now])`. **Verdict: OK.**
- `reachability_probe.dart` (lines 1-15): Abstract `ReachabilityProbe` interface. **Verdict: OK.**

---

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| `OriginKind` wire parsing and strict priority | `OriginKind priority and wire parsing` | Proves all valid wire names parse to expected enum constants, unknown returns null, and priority hierarchy order is strictly monotonic. |
| `PortMapping` lease and expiry calculation | `PortMapping lease and expiry calculation` | Proves `expiresAt` is exactly `createdAt + leaseDuration`, `isExpired` evaluates correctly before and after threshold, and `toString` formats correctly. |
| `GatewayInfo` value equality | `GatewayInfo equality and properties` | Proves identical values evaluate equal with matching hashCodes; differing protocols evaluate non-equal. |
| Interface contract fidelity | `PortMapper and ReachabilityProbe implementation satisfies contract` | Proves mock/fake implementations satisfy all async contract signatures without type errors. |

No tests contain skipped assertions, empty expectations, or catch-all swallows.

---

## 4. Mutation Table
| Mutation Description | Target File / Line | Red Test Result | Post-Restore Diff |
|---|---|---|---|
| Invert priority between `directIpv6` and `mappedIpv4` | `origin_kind.dart:6` | `contract_test.dart` FAIL (rc=1, expected true actual false) | clean (`diff -r` rc=0) |
| Corrupt `PortMapping.expiresAt` by adding 1 second | `port_mapping.dart:36` | `contract_test.dart` FAIL (rc=1, expected 12:30:00 actual 12:30:01) | clean (`diff -r` rc=0) |
| Hardcode `PortMapping.isExpired` to always return false | `port_mapping.dart:38` | `contract_test.dart` FAIL (rc=1, expected true actual false) | clean (`diff -r` rc=0) |

---

## 5. Adversarial Cases Tried
1. **Unknown wire name in `fromWireName`:** Tested empty string `""`, `null`, random string `"bogus"`. All safely return `null` without throwing exceptions.
2. **Negative / Zero lease duration:** `PortMapping` initialized with `Duration.zero` or negative duration. `expiresAt` correctly marks mapping as immediately expired.
3. **Lease boundary equality:** Tested `isExpired(now == expiresAt)`. Correctly evaluates as expired (`now.isAfter(expiresAt) || now.isAtSameMomentAs(expiresAt)`).
4. **Port out-of-range values in `PortMapping`:** Tested negative port and port 70000; correctly carried without crashing DTO layer (range enforcement is in protocol validators in K1/K2).
5. **Concurrent probe requests on `ReachabilityProbe` interface:** Interface signature cleanly supports unbounded concurrent Futures.

---

## 6. Resource and Failure Behaviour
- Pure data models and abstract interfaces; zero socket allocations or persistent background tasks.
- `PortMapper` requires explicit `Future<void> close()` for cleaning up background timers/sockets in implementations.
- No secrets (PIN, token, certificates) are contained in `toString()` or logs.

---

## 7. Compatibility
- Patch applies cleanly to current real tree: `git apply --check -p1 docs/plans/inc5b-proposals/K0/patch.diff` (rc=0).
- Zero modifications to existing tests or production code.
- Pure Dart, zero Flutter dependencies in core.

---

## 8. Verdict
**ACCEPT**

### What the final deep review must re-check:
- Ensure concrete implementations in K1-K4 strictly honor `PortMapper.close()` to guarantee zero unmapped port leaks.
- Ensure `OriginKind.priority` ordering remains synchronized with `CandidateRace` implementation in K3.
