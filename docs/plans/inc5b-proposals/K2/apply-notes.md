# Card K2 Apply Notes

## Summary
Adds fake UPnP IGD router and fake PCP/NAT-PMP server, SSDP discovery client with D4 SSRF hardening, SOAP UPnP IGD client, NAT-PMP client, PCP client, and UnifiedPortMapper with leak prevention.

## Target Files
- `packages/libreshare_core/lib/src/nat/fake_igd_gateway.dart`
- `packages/libreshare_core/lib/src/nat/fake_pcp_server.dart`
- `packages/libreshare_core/lib/src/nat/ssdp.dart`
- `packages/libreshare_core/lib/src/nat/upnp_igd.dart`
- `packages/libreshare_core/lib/src/nat/nat_pmp.dart`
- `packages/libreshare_core/lib/src/nat/pcp.dart`
- `packages/libreshare_core/lib/src/nat/unified_port_mapper.dart`
- `packages/libreshare_core/test/unit/nat/fake_igd_gateway_test.dart`
- `packages/libreshare_core/test/unit/nat/igd_hostile_test.dart`
- `packages/libreshare_core/test/unit/nat/nat_pmp_test.dart`
- `packages/libreshare_core/test/unit/nat/port_mapper_leak_test.dart`

## Application Instructions
```bash
patch -p1 < docs/plans/inc5b-proposals/K2/patch.diff
cp docs/plans/inc5b-proposals/K2/test/unit/nat/* packages/libreshare_core/test/unit/nat/
```

## Verification Steps
```bash
dart analyze --fatal-infos packages/libreshare_core/lib/src/nat/ packages/libreshare_core/test/unit/nat/
dart test packages/libreshare_core/test/unit/nat/
```
