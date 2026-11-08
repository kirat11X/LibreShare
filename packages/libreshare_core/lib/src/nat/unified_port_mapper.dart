// Unified PortMapper implementation for Increment 5b coordinating SSDP, UPnP IGD, NAT-PMP, and PCP.

import 'dart:async';

import 'gateway_info.dart';
import 'nat_pmp.dart';
import 'pcp.dart';
import 'port_mapper.dart';
import 'port_mapping.dart';
import 'ssdp.dart';
import 'upnp_igd.dart';

class UnifiedPortMapper implements PortMapper {
  UnifiedPortMapper({
    SsdpClient? ssdpClient,
    NatPmpClient? natPmpClient,
    PcpClient? pcpClient,
    this.injectedGateway,
  }) : _ssdp = ssdpClient ?? SsdpClient(),
       _natPmp = natPmpClient ?? const NatPmpClient(),
       _pcp = pcpClient ?? const PcpClient();

  final SsdpClient _ssdp;
  final NatPmpClient _natPmp;
  final PcpClient _pcp;
  GatewayInfo? injectedGateway;

  GatewayInfo? _cachedGateway;
  UpnpIgdClient? _upnpClient;
  final List<PortMapping> _managedMappings = [];

  List<PortMapping> get activeMappings => List.unmodifiable(_managedMappings);

  @override
  Future<GatewayInfo?> discoverGateway({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (injectedGateway != null) {
      _cachedGateway = injectedGateway;
      if (injectedGateway!.controlUrl != null) {
        _upnpClient = UpnpIgdClient(controlUrl: injectedGateway!.controlUrl!);
      }
      return _cachedGateway;
    }

    // 1. Try SSDP discovery for UPnP IGD
    try {
      final devices = await _ssdp.discover(timeout: timeout);
      for (final dev in devices) {
        if (dev.controlUrl != null) {
          final upnp = UpnpIgdClient(
            controlUrl: dev.controlUrl!,
            serviceType:
                dev.serviceType ??
                'urn:schemas-upnp-org:service:WANIPConnection:1',
          );
          final extIp = await upnp.getExternalIpAddress(timeout: timeout);
          if (extIp != null) {
            _upnpClient = upnp;
            _cachedGateway = GatewayInfo(
              gatewayIp: dev.controlUrl!.host,
              protocol: GatewayProtocol.upnpIgd,
              externalIp: extIp,
              controlUrl: dev.controlUrl,
              serverHeader: dev.server,
            );
            return _cachedGateway;
          }
        }
      }
    } catch (_) {}

    return null;
  }

  @override
  Future<PortMapping?> requestMapping({
    required int internalPort,
    int? externalPort,
    Duration lease = const Duration(hours: 1),
    PortMappingProtocol protocol = PortMappingProtocol.tcp,
  }) async {
    final gateway = _cachedGateway ?? await discoverGateway();
    if (gateway == null) return null;

    PortMapping? mapping;

    // Route based on gateway protocol
    if (gateway.protocol == GatewayProtocol.upnpIgd && _upnpClient != null) {
      mapping = await _upnpClient!.addPortMapping(
        internalPort: internalPort,
        externalPort: externalPort,
        lease: lease,
        protocol: protocol,
      );
    } else if (gateway.protocol == GatewayProtocol.natPmp) {
      mapping = await _natPmp.addPortMapping(
        gatewayIp: gateway.gatewayIp,
        internalPort: internalPort,
        externalPort: externalPort,
        lease: lease,
        protocol: protocol,
      );
    } else if (gateway.protocol == GatewayProtocol.pcp) {
      mapping = await _pcp.requestMapping(
        gatewayIp: gateway.gatewayIp,
        internalPort: internalPort,
        externalPort: externalPort,
        lease: lease,
        protocol: protocol,
      );
    }

    if (mapping != null) {
      _managedMappings.add(mapping);
    }
    return mapping;
  }

  @override
  Future<bool> releaseMapping(PortMapping mapping) async {
    final gateway = _cachedGateway;
    var success = false;

    if (gateway?.protocol == GatewayProtocol.upnpIgd && _upnpClient != null) {
      success = await _upnpClient!.deletePortMapping(
        externalPort: mapping.externalPort,
        protocol: mapping.protocol,
      );
    } else if (gateway?.protocol == GatewayProtocol.natPmp) {
      success = await _natPmp.deletePortMapping(
        gatewayIp: gateway!.gatewayIp,
        internalPort: mapping.internalPort,
        protocol: mapping.protocol,
      );
    } else {
      success = true; // Best effort for others
    }

    _managedMappings.remove(mapping);
    return success;
  }

  @override
  Future<int> sweepStale() async {
    // Sweeps expired mappings from managed list
    final now = DateTime.now();
    final expired = _managedMappings.where((m) => m.isExpired(now)).toList();
    var count = 0;
    for (final m in expired) {
      final ok = await releaseMapping(m);
      if (ok) count++;
    }
    return count;
  }

  @override
  Future<void> close() async {
    // LEAK PREVENTION: release all active mappings on close/exit
    final toRelease = List<PortMapping>.from(_managedMappings);
    for (final m in toRelease) {
      await releaseMapping(m);
    }
    _managedMappings.clear();
  }
}
