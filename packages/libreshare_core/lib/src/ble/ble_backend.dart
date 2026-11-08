import 'dart:async';

import 'beacon_types.dart';

/// Fixed LibreShare GATT Service and Characteristic UUIDs (design 03 section 3.2).
const String kBleServiceUuid = 'fc7a9155-e024-4269-82a6-433dab94653e';
const String kBleCharRxUuid = 'fc7a9155-e024-4269-82a6-433dab94653f';
const String kBleCharTxUuid = 'fc7a9155-e024-4269-82a6-433dab946540';

/// Discovered BLE peripheral or beacon.
class BleDevice {
  const BleDevice({
    required this.id,
    this.name,
    required this.rssi,
    this.beacon,
    required this.address,
  });

  /// Platform-specific identifier or MAC address.
  final String id;

  /// Advertised local name, if present.
  final String? name;

  /// Received Signal Strength Indication (dBm).
  final int rssi;

  /// Decoded LibreShare manufacturer beacon, if recognized.
  final BleBeacon? beacon;

  /// Hardware BLE address or privacy identifier.
  final String address;

  @override
  String toString() =>
      'BleDevice($id, rssi=$rssi, beacon=${beacon != null}, addr=$address)';
}

/// Filter criteria for BLE scanning.
class BleScanFilter {
  const BleScanFilter({
    this.companyId = kBleCompanyIdSigTest,
    this.serviceUuid = kBleServiceUuid,
  });

  final int? companyId;
  final String? serviceUuid;
}

/// Bidirectional GATT stream session between Central and Peripheral.
abstract class BleGattSession {
  /// Transmits raw data frame over GATT characteristic (RX or TX depending on role).
  Future<void> send(List<int> data);

  /// Incoming stream of frames received from the remote peer.
  Stream<List<int>> get received;

  /// Closes the session and disconnects the underlying GATT channel.
  Future<void> close();

  /// Whether this session is terminated.
  bool get isClosed;
}

/// Local GATT peripheral server listening for incoming central connections.
abstract class BleGattServer {
  /// Starts the local GATT service.
  Future<void> start();

  /// Stops the GATT server.
  Future<void> stop();

  /// Stream of established client sessions.
  Stream<BleGattSession> get incomingSessions;

  /// Whether the server is active.
  bool get isRunning;
}

/// Low-level Bluetooth Low Energy abstraction.
abstract class BleBackend {
  /// Starts emitting a manufacturer-data beacon.
  Future<void> startAdvertising(BleBeacon beacon, {bool connectable = false});

  /// Stops advertising.
  Future<void> stopAdvertising();

  /// Whether beacon advertising is currently active.
  bool get isAdvertising;

  /// Starts scanning for nearby BLE advertisements.
  Stream<BleDevice> scan({BleScanFilter? filter});

  /// Stops an active scan.
  Future<void> stopScan();

  /// Whether scanning is currently active.
  bool get isScanning;

  /// Connects to a remote peripheral and establishes a GATT session.
  Future<BleGattSession> connectGatt(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  });

  /// Local peripheral GATT server instance, or null if peripheral role is unsupported.
  BleGattServer? get gattServer;
}
