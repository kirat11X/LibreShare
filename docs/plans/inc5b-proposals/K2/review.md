# Review: Card K2 (SSDP, UPnP-IGD, NAT-PMP, PCP & Unified Port Mapper)

**Reviewer:** Antigravity Independent Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc5b-proposals/K2/`  
**Verdict:** ACCEPT  

---

## 1. Scope
- **Files added/changed in `patch.diff`:** (7 files, matches `grep -c '^--- ' patch.diff` = 7)
  1. `packages/libreshare_core/lib/src/nat/fake_igd_gateway.dart`
  2. `packages/libreshare_core/lib/src/nat/fake_pcp_server.dart`
  3. `packages/libreshare_core/lib/src/nat/ssdp.dart`
  4. `packages/libreshare_core/lib/src/nat/upnp_igd.dart`
  5. `packages/libreshare_core/lib/src/nat/nat_pmp.dart`
  6. `packages/libreshare_core/lib/src/nat/pcp.dart`
  7. `packages/libreshare_core/lib/src/nat/unified_port_mapper.dart`
- **Test files:**
  1. `packages/libreshare_core/test/unit/nat/fake_igd_gateway_test.dart`
  2. `packages/libreshare_core/test/unit/nat/igd_hostile_test.dart`
  3. `packages/libreshare_core/test/unit/nat/nat_pmp_test.dart`
  4. `packages/libreshare_core/test/unit/nat/port_mapper_leak_test.dart`
- **Spec / Plan references:**
  - `docs/plans/inc5b.md` Section 1, 2, 4 (Wave 2: Fakes, SSDP, UPnP, NAT-PMP, PCP, Unified Mapper)
  - `docs/design/04-link-qr-and-free-internet-paths.md` section 5.2 (SSDP discovery, UPnP SOAP actions, NAT-PMP opcodes, PCP MAP opcode, D4 SSRF rules)

---

## 2. Diff Read
- `fake_igd_gateway.dart` (lines 1-237): Hermetic HTTP test server simulating IGD SOAP endpoints, error codes (718 conflict, 725 permanent-only, 501, 606), oversize XML, and DTD attacks. **Verdict: OK.**
- `fake_pcp_server.dart` (lines 1-127): Hermetic UDP test server simulating NAT-PMP and PCP response payloads. **Verdict: OK.**
- `ssdp.dart` (lines 1-240): SSDP M-SEARCH discovery with D4 SSRF mitigations: enforces HTTP scheme, private/link-local address check on LOCATION URL, `followRedirects = false`, strict 64 KiB XML size cap, DTD/entity blocking (`<!DOCTYPE` / `<!ENTITY`), same-origin control URL resolution. **Verdict: OK (Security-Critical).**
- `upnp_igd.dart` (lines 1-163): SOAP client executing `GetExternalIPAddress`, `AddPortMapping`, and `DeletePortMapping`. Automatically retries external ports on 718 conflict; falls back to permanent lease on 725. **Verdict: OK (Security-Critical).**
- `nat_pmp.dart` (lines 1-152): RFC 6886 NAT-PMP client. Parses public IP (opcode 0) and port mapping requests (opcodes 1, 2). **Verdict: OK (Security-Critical).**
- `pcp.dart` (lines 1-102): RFC 6887 Port Control Protocol client. Handles opcode 1 (MAP). **Verdict: OK (Security-Critical).**
- `unified_port_mapper.dart` (lines 1-137): Unified orchestrator coordinating router discovery, lease acquisition, and guaranteed unmapping on `close()`. **Verdict: OK.**

---

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| D4 SSRF: Hostile Public IP rejection | `Rejects hostile public IP in LOCATION URL` | Proves SSDP client rejects public IP LOCATION URLs (e.g. `http://8.8.8.8:8080/desc.xml`). |
| D4 SSRF: Non-HTTP Scheme rejection | `Rejects non-HTTP scheme in LOCATION URL` | Proves `file://`, `ftp://`, or javascript schemes are aborted immediately. |
| D4 SSRF: Oversize XML cap (64 KiB) | `Rejects oversize XML (> 64 KiB)` | Proves responses exceeding 65,536 bytes are aborted without buffering. |
| D4 SSRF: DTD / Entity expansion block | `Rejects XML containing DOCTYPE or ENTITY` | Proves entity expansion attacks are neutralized before XML parsing. |
| 718 Conflict Handling | `Handles 718 conflict by incrementing port` | Proves client attempts `externalPort + 1` when gateway reports conflict. |
| 725 Permanent Lease Fallback | `Handles 725 permanent-only lease error` | Proves client re-requests with lease=0 when gateway disallows temporary leases. |
| Mapping Leak Prevention on Exit | `Leak Prevention: close() releases all active mappings` | Proves `mapper.close()` dispatches `DeletePortMapping` for all tracked leases. |

---

## 4. Mutation Table
| Mutation Description | Target File / Line | Red Test Result | Post-Restore Diff |
|---|---|---|---|
| Remove XML size cap check (`length > 65536`) | `ssdp.dart:187` | `igd_hostile_test.dart` FAIL (oversize XML accepted) | clean (`diff -r` rc=0) |
| Remove DTD/entity pattern check (`<!DOCTYPE`) | `ssdp.dart:194` | `igd_hostile_test.dart` FAIL (DTD XML accepted) | clean (`diff -r` rc=0) |
| Invert D4 private IP filter in `_isAllowedHost` | `ssdp.dart:218` | `igd_hostile_test.dart` FAIL (public IP accepted) | clean (`diff -r` rc=0) |
| Disable unmapping in `UnifiedPortMapper.close()` | `unified_port_mapper.dart:118` | `port_mapper_leak_test.dart` FAIL (mappings survive close) | clean (`diff -r` rc=0) |

---

## 5. Adversarial Cases Tried
1. **SSRF Redirect Attack:** Hostile gateway returns HTTP 302 to internal loopback or cloud metadata endpoint. Client explicitly configures `HttpClientRequest.followRedirects = false`, preventing redirect traversal.
2. **Infinite Stream / Slowloris Gateway:** Gateway streams bytes slowly without closing. Client imposes bounded `deadline` and chunk limit.
3. **SOAP Fault 501 / Action Failed:** Gateway rejects mapping creation. Client logs warning and returns `null` without throwing unhandled exceptions.
4. **NAT-PMP Gateway Return Code Non-Zero:** Gateway responds with error result code (e.g. 3 = Network Failure). Client returns `null`.
5. **Simultaneous `requestMapping` calls during `close()`:** Mutex guard ensures no orphan mappings are initiated after teardown begins.

---

## 6. Resource and Failure Behaviour
- All test gateways bind to ephemeral port 0 (`HttpServer.bind(..., 0)`, `RawDatagramSocket.bind(..., 0)`).
- `UnifiedPortMapper.close()` deletes all active mappings sequentially and closes sockets.
- Zero secrets, keys, or auth headers are transmitted or logged.

---

## 7. Compatibility
- Patch applies cleanly to tree + K0 + K1: `git apply --check -p1 docs/plans/inc5b-proposals/K2/patch.diff` (rc=0).
- Pure Dart, zero Flutter dependencies in core.

---

## 8. Verdict
**ACCEPT**

### What the final deep review must re-check:
- Verify that `UnifiedPortMapper` integration into `LibreShareEngine` (K4/K5) registers shutdown hooks (`engine.stop()`) to ensure router mappings are swept on process termination.
