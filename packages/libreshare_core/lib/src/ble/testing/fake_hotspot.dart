import 'dart:async';

import '../hotspot_backend.dart';

class _FakeAirNetwork {
  _FakeAirNetwork({
    required this.ssid,
    required this.psk,
    required this.hostIp,
    required this.port,
  });

  final String ssid;
  final String psk;
  final String hostIp;
  final int port;
  bool isBlackholed = false;
  final Set<_FakeJoinResult> joinedClients = {};
}

/// Simulated in-memory Wi-Fi radio medium for ad-hoc hotspot testing.
class FakeAir {
  final Map<String, _FakeAirNetwork> _networks = {};

  void publishNetwork({
    required String ssid,
    required String psk,
    required String hostIp,
    required int port,
  }) {
    _networks[ssid] = _FakeAirNetwork(
      ssid: ssid,
      psk: psk,
      hostIp: hostIp,
      port: port,
    );
  }

  void withdrawNetwork(String ssid) {
    final net = _networks.remove(ssid);
    if (net != null) {
      for (final client in List.of(net.joinedClients)) {
        client._onDisconnectedByAir();
      }
    }
  }

  /// Simulates a physical radio drop / netem blackhole.
  void cut(String ssid) {
    final net = _networks[ssid];
    if (net != null) {
      net.isBlackholed = true;
      for (final client in List.of(net.joinedClients)) {
        client._onDisconnectedByAir();
      }
    }
  }

  /// Restores network after a cut.
  void restore(String ssid) {
    final net = _networks[ssid];
    if (net != null) {
      net.isBlackholed = false;
    }
  }

  bool isAvailable(String ssid) {
    final net = _networks[ssid];
    return net != null && !net.isBlackholed;
  }
}

class _FakeReservation implements HotspotReservation {
  _FakeReservation(this._backend, this.ssid, this.psk, this.hostIp, this.port);

  final FakeHotspotBackend _backend;
  @override
  final String ssid;
  @override
  final String psk;
  @override
  final String hostIp;
  @override
  final int port;
  bool _stopped = false;

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _backend._onReservationStopped(this);
  }
}

class _FakeJoinResult implements HotspotJoinResult {
  _FakeJoinResult(this._backend, this.clientIp, this.gatewayIp, this._network);

  final FakeHotspotBackend _backend;
  @override
  final String clientIp;
  @override
  final String gatewayIp;
  final _FakeAirNetwork _network;
  bool _disconnected = false;

  final Completer<void> _disconnectedCompleter = Completer<void>();
  Future<void> get onDisconnected => _disconnectedCompleter.future;

  @override
  Future<void> disconnect() async {
    if (_disconnected) return;
    _disconnected = true;
    _network.joinedClients.remove(this);
    _backend._onJoinDisconnected(this);
    if (!_disconnectedCompleter.isCompleted) {
      _disconnectedCompleter.complete();
    }
  }

  void _onDisconnectedByAir() {
    if (_disconnected) return;
    _disconnected = true;
    _network.joinedClients.remove(this);
    _backend._onJoinDisconnected(this);
    if (!_disconnectedCompleter.isCompleted) {
      _disconnectedCompleter.complete();
    }
  }
}

/// Simulated implementation of [HotspotBackend].
class FakeHotspotBackend implements HotspotBackend {
  FakeHotspotBackend({
    FakeAir? air,
    this.canHost = true,
    this.canJoin = true,
    this.hostKeepsUplink = false,
    this.defaultHostIp = '192.168.49.1',
    this.defaultClientIp = '192.168.49.2',
  }) : air = air ?? FakeAir();

  final FakeAir air;
  @override
  final bool canHost;
  @override
  final bool canJoin;
  @override
  final bool hostKeepsUplink;
  final String defaultHostIp;
  final String defaultClientIp;

  final List<_FakeReservation> _activeReservations = [];
  final List<_FakeJoinResult> _activeJoins = [];

  int get activeReservationsCount => _activeReservations.length;
  int get activeJoinsCount => _activeJoins.length;
  int teardownCalls = 0;

  @override
  Future<HotspotReservation> startHotspot({
    required String ssid,
    required String psk,
    int port = 53318,
  }) async {
    if (!canHost) {
      throw UnsupportedError('This backend cannot host hotspots');
    }
    air.publishNetwork(ssid: ssid, psk: psk, hostIp: defaultHostIp, port: port);
    final reservation = _FakeReservation(this, ssid, psk, defaultHostIp, port);
    _activeReservations.add(reservation);
    return reservation;
  }

  @override
  Future<HotspotJoinResult> joinHotspot({
    required String ssid,
    required String psk,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (!canJoin) {
      throw UnsupportedError('This backend cannot join hotspots');
    }
    final net = air._networks[ssid];
    if (net == null || net.isBlackholed) {
      throw TimeoutException('Hotspot network $ssid not found on air', timeout);
    }
    if (net.psk != psk) {
      throw StateError('Authentication failed: PSK mismatch for $ssid');
    }

    final joinResult = _FakeJoinResult(this, defaultClientIp, net.hostIp, net);
    net.joinedClients.add(joinResult);
    _activeJoins.add(joinResult);
    return joinResult;
  }

  void _onReservationStopped(_FakeReservation reservation) {
    _activeReservations.remove(reservation);
    air.withdrawNetwork(reservation.ssid);
    teardownCalls++;
  }

  void _onJoinDisconnected(_FakeJoinResult joinResult) {
    _activeJoins.remove(joinResult);
    teardownCalls++;
  }

  /// Cleanly closes all active reservations and joins.
  Future<void> dispose() async {
    for (final res in List.of(_activeReservations)) {
      await res.stop();
    }
    for (final join in List.of(_activeJoins)) {
      await join.disconnect();
    }
  }
}
