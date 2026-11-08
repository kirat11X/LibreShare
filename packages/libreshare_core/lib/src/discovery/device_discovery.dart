/// Discovery contracts (spec §4.2, UML DeviceDiscovery 1.0). Orchestrator-owned.
library;

import '../model/device.dart';

enum DiscoverySource { multicast, mdns, subnetScan, manual, qr, register, ble }

/// A peer currently believed to be reachable.
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.info,
    required this.address,
    required this.lastSeen,
    required this.source,
  });

  final DeviceInfo info;

  /// Address we actually heard it from / probed successfully (preferred first hop).
  final String address;
  final DateTime lastSeen;
  final DiscoverySource source;

  String get id => info.deviceId;
}

sealed class DiscoveryEvent {
  const DiscoveryEvent(this.device);
  final DiscoveredDevice device;
}

class DeviceFound extends DiscoveryEvent {
  const DeviceFound(super.device);
}

class DeviceUpdated extends DiscoveryEvent {
  const DeviceUpdated(super.device);
}

class DeviceLost extends DiscoveryEvent {
  const DeviceLost(super.device);
}

/// Anything that learns about peers (multicast, mDNS, subnet scan, manual/QR,
/// POST /register) reports them here. Implemented by PeerRegistry.
abstract interface class PeerSink {
  /// Records/refreshes [info] heard at [address]. Own deviceId must be ignored.
  void seen(DeviceInfo info, String address, DiscoverySource source);
}

/// POST /register to a peer on behalf of the multicast listener (spec §4.2:
/// "reply POST to `/api/v1/register` on the peer; if it fails in 2 s, reply
/// UDP unicast announce:false"). Returns true if the peer accepted.
typedef PeerRegistrar = Future<bool> Function(DeviceInfo peer, String address);

abstract interface class DeviceDiscovery {
  /// Snapshot of live peers; emits on every change.
  Stream<List<DiscoveredDevice>> get devices;
  Stream<DiscoveryEvent> get events;
  List<DiscoveredDevice> get current;

  Future<void> start();
  Future<void> stop();

  /// Re-announce now and (if configured) trigger a subnet scan.
  Future<void> refresh();
}
