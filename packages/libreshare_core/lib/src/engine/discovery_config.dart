/// How a `LibreShareEngine` finds other devices (spec section 4.2). Everything
/// that touches the network is injectable so tests can run two or three
/// engines in one process without UDP 53318 or a real LAN.
library;

import 'dart:typed_data';

import '../ble/ble_backend.dart';
import '../ble/ble_coordinator.dart';
import '../ble/visibility_manager.dart';
import '../discovery/mdns_backend.dart';
import '../discovery/multicast_transport.dart';
import '../discovery/network_interfaces.dart';
import '../discovery/subnet_scanner.dart';
import '../protocol.dart';

class DiscoveryConfig {
  const DiscoveryConfig({
    this.enabled = true,
    this.multicastTransport,
    this.interfaces = const SystemNetworkInterfaceProvider(),
    this.mdns,
    this.autoScan = true,
    this.autoScanDelay = ScanPolicy.defaultDelay,
    this.scanPort = kDefaultPort,
    this.allowLoopbackScan = false,
    this.scanTimeout = SubnetScanner.defaultTimeout,
    this.scanConcurrency = SubnetScanner.defaultConcurrency,
    this.infoProbe,
    this.announceSchedule = const [Duration(seconds: 1), Duration(seconds: 3)],
    this.announceInterval = const Duration(seconds: 30),
    this.interfacePoll = const Duration(seconds: 5),
    this.registerTimeout = const Duration(seconds: 2),
    this.peerExpiry = const Duration(seconds: 90),
    this.bleBackend,
    this.bleVisibility,
    this.advKey,
    this.onBleTransferPrompt,
  });

  /// No multicast, no automatic scan, no mDNS. The engine still resolves
  /// manual/QR peers, scans on demand and sends. This is the engine's default
  /// so a plain `LibreShareEngine(...)` touches no network beyond its listener.
  static const DiscoveryConfig disabled = DiscoveryConfig(enabled: false);

  /// Run multicast announce/listen, the automatic scan and mDNS.
  final bool enabled;

  /// Creates the multicast transport on every start. Null: a
  /// [RawMulticastTransport] on UDP 53318. Tests pass an in-memory bus.
  final MulticastTransport Function()? multicastTransport;

  /// Local interface enumeration (addresses to announce, networks to scan).
  final NetworkInterfaceProvider interfaces;

  /// Optional mDNS (`_libreshare._tcp`); the app layer supplies `bonsoir`.
  /// Advertised only while receiving; browsed peers enter the registry as
  /// `DiscoverySource.mdns`.
  final MdnsBackend? mdns;

  /// Scan the local /24 once, [autoScanDelay] after start (and after the last
  /// peer is lost) when no peer is known (spec 4.2 rule 4).
  final bool autoScan;
  final Duration autoScanDelay;

  /// TCP port probed by the scan (peers on a fallback port are not found).
  final int scanPort;

  /// Tests only: also sweep 127/8.
  final bool allowLoopbackScan;
  final Duration scanTimeout;
  final int scanConcurrency;

  /// Replaces the HTTP `GET /info` probe of the scan and of manual peers.
  final InfoProbe? infoProbe;

  /// Extra announcements after the first one (spec: +1 s, +3 s) ...
  final List<Duration> announceSchedule;

  /// ... then this often (spec: 30 s).
  final Duration announceInterval;
  final Duration interfacePoll;

  /// `POST /register` budget before falling back to a UDP reply (spec: 2 s).
  final Duration registerTimeout;

  /// A peer not heard from for this long is dropped (spec: 90 s).
  final Duration peerExpiry;

  /// Optional BLE backend for out-of-band discovery & transfer handoff (Increment 7).
  final BleBackend? bleBackend;

  /// Optional preconfigured visibility manager for BLE advertising.
  final VisibilityManager? bleVisibility;

  /// Optional 32-byte shared beacon derivation key (advKey).
  final Uint8List? advKey;

  /// Transfer prompt consent handler for incoming BLE transfer offers.
  final Future<bool> Function(BleTransferPrompt prompt)? onBleTransferPrompt;
}
