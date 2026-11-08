# Increment 5b Seams & Wave 0 Contracts

**Author:** Lead  
**Date:** 2026-11-07  
**Scope:** Wave 0 interface signatures and data models for Increment 5b (IPv6, UPnP/NAT-PMP/PCP, Hide My IP).  
**References:** `docs/plans/inc5b.md`, `docs/design/04-link-qr-and-free-internet-paths.md` sections 2-5.

---

## 1. Contracts & Signatures

### 1.1 `packages/libreshare_core/lib/src/nat/origin_kind.dart`
Represents the transport/origin category for candidate racing and link encoding:
```dart
enum OriginKind {
  directIpv6('ipv6', priority: 10),
  mappedIpv4('mapped4', priority: 20),
  tunnelCloudflare('cf', priority: 30),
  tunnelZrok('zrok', priority: 40),
  manual('manual', priority: 50);

  const OriginKind(this.wireName, {required this.priority});
  final String wireName;
  final int priority;

  static OriginKind? fromWireName(String name);
}
```

### 1.2 `packages/libreshare_core/lib/src/nat/port_mapping.dart`
Represents an active or requested port mapping on an external gateway:
```dart
enum PortMappingProtocol { tcp('TCP'), udp('UDP'); ... }

final class PortMapping {
  const PortMapping({
    required this.internalPort,
    required this.externalPort,
    required this.externalIp,
    required this.protocol,
    required this.leaseDuration,
    required this.createdAt,
    this.description = 'LibreShare',
  });

  final int internalPort;
  final int externalPort;
  final String externalIp;
  final PortMappingProtocol protocol;
  final Duration leaseDuration;
  final DateTime createdAt;
  final String description;

  DateTime get expiresAt;
  bool isExpired([DateTime? now]);
}
```

### 1.3 `packages/libreshare_core/lib/src/nat/gateway_info.dart`
Represents router metadata discovered via SSDP/NAT-PMP/PCP:
```dart
enum GatewayProtocol { upnpIgd, natPmp, pcp, manual }

final class GatewayInfo {
  const GatewayInfo({
    required this.gatewayIp,
    required this.protocol,
    required this.externalIp,
    this.controlUrl,
    this.serverHeader,
  });

  final String gatewayIp;
  final GatewayProtocol protocol;
  final String externalIp;
  final Uri? controlUrl;
  final String? serverHeader;
}
```

### 1.4 `packages/libreshare_core/lib/src/nat/port_mapper.dart`
Unified port mapping service interface:
```dart
abstract interface class PortMapper {
  Future<GatewayInfo?> discoverGateway({Duration timeout = const Duration(seconds: 3)});
  Future<PortMapping?> requestMapping({
    required int internalPort,
    int? externalPort,
    Duration lease = const Duration(hours: 1),
    PortMappingProtocol protocol = PortMappingProtocol.tcp,
  });
  Future<bool> releaseMapping(PortMapping mapping);
  Future<int> sweepStale();
  Future<void> close();
}
```

### 1.5 `packages/libreshare_core/lib/src/nat/reachability_probe.dart`
External reachability verifier:
```dart
abstract interface class ReachabilityProbe {
  Future<bool> probe({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 3),
  });
}
```

---

## 2. Protocol & Schema Changes
- `tunnel-offer.schema.json` gains optional `candidates` (array of max 4 strings `kind:host:port`) and `pin` (64-character SHA-256 hex string).
- LSP-1 Section 4.5: Direct origin paths reuse tunnel origin HTTP routes over ephemeral TLS verified via pinned SHA-256 fingerprint.
