import 'dart:async';
import 'dart:typed_data';

import '../beacon_types.dart';
import '../ble_backend.dart';
import '../gatt_frame_codec.dart';

/// One active advertisement on the fake bus.
class FakeBleAdvertisement {
  const FakeBleAdvertisement({
    required this.deviceId,
    required this.address,
    this.name,
    required this.beacon,
    required this.rssi,
    required this.connectable,
  });

  final String deviceId;
  final String address;
  final String? name;
  final BleBeacon beacon;
  final int rssi;
  final bool connectable;
}

/// In-memory simulated Bluetooth Low Energy medium.
class FakeBleBus {
  FakeBleBus({
    this.defaultMtu = kDefaultGattMtu,
    this.simulatedLatency = Duration.zero,
  });

  final int defaultMtu;
  final Duration simulatedLatency;

  final Map<String, FakeBleAdvertisement> _advertisements = {};
  final Map<String, FakeBleGattServer> _servers = {};
  final List<StreamController<BleDevice>> _activeScanners = [];

  /// Registers or updates an active advertisement on the bus.
  void advertise(FakeBleAdvertisement ad) {
    _advertisements[ad.deviceId] = ad;
    _broadcastToScanners(ad);
  }

  /// Removes an active advertisement.
  void stopAdvertising(String deviceId) {
    _advertisements.remove(deviceId);
  }

  void _broadcastToScanners(FakeBleAdvertisement ad) {
    final dev = BleDevice(
      id: ad.deviceId,
      name: ad.name,
      rssi: ad.rssi,
      beacon: ad.beacon,
      address: ad.address,
    );
    for (final scanner in List.of(_activeScanners)) {
      if (!scanner.isClosed) {
        scanner.add(dev);
      }
    }
  }

  Stream<BleDevice> createScanStream(
    String scannerId, {
    BleScanFilter? filter,
  }) {
    late final StreamController<BleDevice> controller;
    controller = StreamController<BleDevice>(
      onListen: () {
        _activeScanners.add(controller);
        // Immediately yield currently active advertisements that match filter
        for (final ad in _advertisements.values) {
          if (ad.deviceId == scannerId) continue; // don't hear self
          if (filter != null &&
              filter.companyId != null &&
              ad.beacon.companyId != filter.companyId) {
            continue;
          }
          final dev = BleDevice(
            id: ad.deviceId,
            name: ad.name,
            rssi: ad.rssi,
            beacon: ad.beacon,
            address: ad.address,
          );
          controller.add(dev);
        }
      },
      onCancel: () {
        _activeScanners.remove(controller);
      },
    );
    return controller.stream;
  }

  /// Registers a GATT server on the bus.
  void registerServer(String deviceId, FakeBleGattServer server) {
    _servers[deviceId] = server;
  }

  void unregisterServer(String deviceId) {
    _servers.remove(deviceId);
  }

  /// Connects to a registered target GATT server.
  Future<BleGattSession> connect(
    String clientDeviceId,
    String targetDeviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final server = _servers[targetDeviceId];
    if (server == null || !server.isRunning) {
      throw TimeoutException(
        'No active GATT server found for device $targetDeviceId',
        timeout,
      );
    }

    final clientToTarget = StreamController<List<int>>();
    final targetToClient = StreamController<List<int>>();

    final clientSession = FakeBleGattSession._(
      outbound: clientToTarget,
      inbound: targetToClient.stream,
      latency: simulatedLatency,
    );

    final serverSession = FakeBleGattSession._(
      outbound: targetToClient,
      inbound: clientToTarget.stream,
      latency: simulatedLatency,
    );

    server._acceptSession(serverSession);
    return clientSession;
  }

  /// Creates a [BleBackend] attached to this bus.
  FakeBleBackend createBackend({
    required String deviceId,
    required String address,
    String? name,
    int rssi = -60,
  }) {
    return FakeBleBackend._(
      bus: this,
      deviceId: deviceId,
      address: address,
      name: name,
      rssi: rssi,
    );
  }
}

/// Simulated GATT session endpoint.
class FakeBleGattSession implements BleGattSession {
  FakeBleGattSession._({
    required this.outbound,
    required this.inbound,
    required this.latency,
  });

  final StreamController<List<int>> outbound;
  final Stream<List<int>> inbound;
  final Duration latency;
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Stream<List<int>> get received => inbound;

  @override
  Future<void> send(List<int> data) async {
    if (_closed) throw StateError('GATT session is closed');
    final copy = Uint8List.fromList(data);
    if (latency > Duration.zero) {
      await Future<void>.delayed(latency);
    }
    if (!_closed && !outbound.isClosed) {
      outbound.add(copy);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!outbound.isClosed) {
      await outbound.close();
    }
  }
}

/// Simulated peripheral GATT server.
class FakeBleGattServer implements BleGattServer {
  FakeBleGattServer._(this._bus, this._deviceId);

  final FakeBleBus _bus;
  final String _deviceId;
  bool _running = false;
  final StreamController<BleGattSession> _incoming =
      StreamController<BleGattSession>.broadcast();

  @override
  bool get isRunning => _running;

  @override
  Stream<BleGattSession> get incomingSessions => _incoming.stream;

  @override
  Future<void> start() async {
    _running = true;
    _bus.registerServer(_deviceId, this);
  }

  @override
  Future<void> stop() async {
    _running = false;
    _bus.unregisterServer(_deviceId);
  }

  void _acceptSession(FakeBleGattSession session) {
    if (_running && !_incoming.isClosed) {
      _incoming.add(session);
    }
  }

  void dispose() {
    _running = false;
    _bus.unregisterServer(_deviceId);
    _incoming.close();
  }
}

/// In-memory fake implementation of [BleBackend].
class FakeBleBackend implements BleBackend {
  FakeBleBackend._({
    required this.bus,
    required this.deviceId,
    required this.address,
    this.name,
    this.rssi = -60,
  }) : _server = FakeBleGattServer._(bus, deviceId);

  final FakeBleBus bus;
  final String deviceId;
  final String address;
  final String? name;
  final int rssi;

  final FakeBleGattServer _server;
  bool _advertising = false;
  bool _scanning = false;
  StreamSubscription<BleDevice>? _scanSub;

  @override
  BleGattServer get gattServer => _server;

  @override
  bool get isAdvertising => _advertising;

  @override
  bool get isScanning => _scanning;

  @override
  Future<void> startAdvertising(
    BleBeacon beacon, {
    bool connectable = false,
  }) async {
    _advertising = true;
    if (connectable) {
      await _server.start();
      bus.registerServer(deviceId, _server);
    }
    bus.advertise(
      FakeBleAdvertisement(
        deviceId: deviceId,
        address: address,
        name: name,
        beacon: beacon,
        rssi: rssi,
        connectable: connectable,
      ),
    );
  }

  @override
  Future<void> stopAdvertising() async {
    _advertising = false;
    bus.stopAdvertising(deviceId);
  }

  @override
  Stream<BleDevice> scan({BleScanFilter? filter}) {
    _scanning = true;
    return bus.createScanStream(deviceId, filter: filter);
  }

  @override
  Future<void> stopScan() async {
    _scanning = false;
    await _scanSub?.cancel();
    _scanSub = null;
  }

  @override
  Future<BleGattSession> connectGatt(
    String targetDeviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    return bus.connect(deviceId, targetDeviceId, timeout: timeout);
  }

  Future<void> dispose() async {
    await stopAdvertising();
    await stopScan();
    await _server.stop();
    _server.dispose();
  }
}
