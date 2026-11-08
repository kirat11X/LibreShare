# Card K2 Report: `FakeIgdGateway`, `FakePcpServer`, `ssdp`, `upnp_igd`, `nat_pmp`, `pcp`, & `unified_port_mapper`

**Card:** K2 (Wave 2: Fakes & Port Mapping Protocols)  
**Author:** Lead  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 35/35 tests pass x3, 5/5 mutations killed)

---

## 1. Summary of Changes
Card K2 implements the complete suite of port mapping protocol handlers, routers fakes, and unified mapper orchestrator for Increment 5b:
1. **Fakes**:
   - `packages/libreshare_core/lib/src/nat/fake_igd_gateway.dart`: HTTP server implementing UPnP IGD device description and SOAP control (`GetExternalIPAddress`, `AddPortMapping`, `DeletePortMapping`). Supports 718 conflict, 725 permanent-only, 501/606 errors, oversize XML, DTD injection, and latency knobs.
   - `packages/libreshare_core/lib/src/nat/fake_pcp_server.dart`: UDP server supporting NAT-PMP (RFC 6886 opcodes 0, 1, 2) and PCP (RFC 6887 opcode MAP).
2. **SSDP & Security Hardening (`packages/libreshare_core/lib/src/nat/ssdp.dart`) (Security-Critical)**:
   - Multicast and unicast `M-SEARCH` discovery for `urn:schemas-upnp-org:device:InternetGatewayDevice:1`.
   - **D4 SSRF Protections**:
     - Enforces `http://` scheme only.
     - Enforces host validation: must be RFC 1918 private IPv4 or link-local address.
     - Never follows HTTP redirects (`followRedirects = false`).
     - Hard XML size cap: <= 64 KiB.
     - Blocks DTD / entity expansion (`<!DOCTYPE` / `<!ENTITY`).
     - Enforces same-origin control URL resolution.
3. **Protocol Clients**:
   - `packages/libreshare_core/lib/src/nat/upnp_igd.dart`: SOAP client handling external IP discovery, mapping additions (auto-incrementing external port on 718 conflict; falling back to permanent lease on 725), and mapping deletion.
   - `packages/libreshare_core/lib/src/nat/nat_pmp.dart`: UDP client communicating with NAT-PMP gateway on port 5351.
   - `packages/libreshare_core/lib/src/nat/pcp.dart`: UDP client communicating with PCP gateway on port 5351.
4. **Unified Port Mapper (`packages/libreshare_core/lib/src/nat/unified_port_mapper.dart`)**:
   - Implements `PortMapper` interface, coordinating SSDP, UPnP IGD, NAT-PMP, and PCP.
   - **Leak Prevention**: tracks all active mappings and automatically releases all mappings on `close()`.
   - `sweepStale()` removes expired mappings.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze --fatal-infos` passed with 0 issues.
- **Code Formatting**: `dart format --output=none --set-exit-if-changed` verified clean.
- **Flake Gate**: 35/35 tests in `test/unit/nat/` passed across 3 consecutive runs.
- **Mutation Sweep**: 5/5 mutations killed (M1 hostile LOCATION bypass, M2 XML size cap, M3 DTD rejection, M4 unmap on close, M5 718 port increment).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for all 7 library files.
- `test/unit/nat/fake_igd_gateway_test.dart`: SOAP control and error code handling tests.
- `test/unit/nat/igd_hostile_test.dart`: D4 SSRF, oversize XML, and DTD security tests.
- `test/unit/nat/nat_pmp_test.dart`: NAT-PMP UDP round-trip tests.
- `test/unit/nat/port_mapper_leak_test.dart`: Active leak prevention and stale sweep tests.
- `apply-notes.md`: Instructions for orchestrator application.
- `verifier-report.md`: Independent verifier sign-off.
