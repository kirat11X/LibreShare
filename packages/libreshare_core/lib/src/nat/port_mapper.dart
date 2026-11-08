// Port mapper interface for Increment 5b UPnP/NAT-PMP/PCP.

import 'gateway_info.dart';
import 'port_mapping.dart';

abstract interface class PortMapper {
  /// Discovers the local router / NAT gateway via SSDP/NAT-PMP/PCP.
  Future<GatewayInfo?> discoverGateway({
    Duration timeout = const Duration(seconds: 3),
  });

  /// Requests a port mapping for [internalPort] on the discovered gateway.
  /// If [externalPort] is not specified, internalPort is requested.
  /// Lease duration is capped at 1 hour (per D1).
  Future<PortMapping?> requestMapping({
    required int internalPort,
    int? externalPort,
    Duration lease = const Duration(hours: 1),
    PortMappingProtocol protocol = PortMappingProtocol.tcp,
  });

  /// Releases/deletes the specified [mapping] from the router.
  Future<bool> releaseMapping(PortMapping mapping);

  /// Sweeps stale mappings created by previous runs of LibreShare on this device.
  Future<int> sweepStale();

  /// Closes any open sockets, timers, or resources.
  Future<void> close();
}
