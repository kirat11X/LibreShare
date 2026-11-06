import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Traffic direction for directional fault injection and statistics.
enum ProxyDirection {
  /// Traffic flowing from the client to the upstream server.
  clientToServer,

  /// Traffic flowing from the upstream server back to the client.
  serverToClient,

  /// Traffic in either or both directions.
  both;

  /// Returns true if this direction filter matches [actual].
  bool matches(ProxyDirection actual) {
    if (this == ProxyDirection.both) return true;
    return this == actual;
  }
}

/// Statistics tracked across connections forwarded through [FaultyTcpProxy].
class ProxyStats {
  /// Total bytes successfully forwarded across all connections.
  int totalBytesForwarded = 0;

  /// Total bytes forwarded from client to server.
  int clientToServerBytes = 0;

  /// Total bytes forwarded from server to client.
  int serverToClientBytes = 0;

  /// Total packets/chunks delayed by artificial latency.
  int packetsDelayed = 0;

  /// Total fault injection events triggered (cuts, truncations, resets, bit flips).
  int faultsTriggered = 0;

  /// Total incoming client connections accepted.
  int connectionsAccepted = 0;

  /// Total connections closed or destroyed.
  int connectionsClosed = 0;

  /// Resets all counters to zero.
  void reset() {
    totalBytesForwarded = 0;
    clientToServerBytes = 0;
    serverToClientBytes = 0;
    packetsDelayed = 0;
    faultsTriggered = 0;
    connectionsAccepted = 0;
    connectionsClosed = 0;
  }

  /// Creates a snapshot copy of current statistics.
  ProxyStats copy() {
    final s = ProxyStats();
    s.totalBytesForwarded = totalBytesForwarded;
    s.clientToServerBytes = clientToServerBytes;
    s.serverToClientBytes = serverToClientBytes;
    s.packetsDelayed = packetsDelayed;
    s.faultsTriggered = faultsTriggered;
    s.connectionsAccepted = connectionsAccepted;
    s.connectionsClosed = connectionsClosed;
    return s;
  }

  @override
  String toString() =>
      'ProxyStats(forwarded: $totalBytesForwarded, delayed: $packetsDelayed, faults: $faultsTriggered, connections: $connectionsAccepted)';
}

/// Base class for declarative fault actions in a [FaultyTcpProxy] schedule.
sealed class FaultAction {
  const FaultAction();

  /// Closes the connection abruptly after transferring [bytes].
  const factory FaultAction.cutAfter(
    int bytes, {
    ProxyDirection direction,
    bool perConnection,
  }) = CutAfterAction;

  /// Adds artificial latency to packets/chunks.
  const factory FaultAction.delay(
    Duration latency, {
    ProxyDirection direction,
    int? packetCount,
    int? atBytes,
  }) = DelayAction;

  /// Sends the first [maxBytes] then terminates with TCP FIN (or RST if [abrupt]).
  const factory FaultAction.truncate(
    int maxBytes, {
    ProxyDirection direction,
    bool abrupt,
    bool perConnection,
    int? atBytes,
  }) = TruncateAction;

  /// Forcefully resets the connection (SocketDirection.both destroy).
  const factory FaultAction.reset({int? atBytes, bool futureConnections}) =
      ResetAction;

  /// Flips bits in payload with seeded randomness.
  const factory FaultAction.bitFlip(
    double probability, {
    ProxyDirection direction,
    int? atBytes,
  }) = BitFlipAction;

  /// Passes traffic through cleanly for [bytes] before subsequent faults engage.
  const factory FaultAction.passThrough({int? bytes}) = PassThroughAction;

  /// Generates a deterministic sequence of random fault actions from a [seed].
  ///
  /// Useful for NFR-03 20 randomized fault runs.
  static List<FaultAction> generateRandomSchedule(
    int seed, {
    int minActions = 1,
    int maxActions = 4,
  }) {
    final rng = Random(seed);
    final count =
        minActions +
        (maxActions > minActions
            ? rng.nextInt(maxActions - minActions + 1)
            : 0);
    final actions = <FaultAction>[];
    final types = <int>[0, 1, 2, 3, 4]..shuffle(rng);

    for (var i = 0; i < count; i++) {
      final t = types[i % types.length];
      switch (t) {
        case 0:
          actions.add(
            FaultAction.delay(Duration(milliseconds: 10 + rng.nextInt(90))),
          );
          break;
        case 1:
          actions.add(FaultAction.cutAfter(100 + rng.nextInt(900)));
          break;
        case 2:
          actions.add(
            FaultAction.truncate(
              100 + rng.nextInt(900),
              abrupt: rng.nextBool(),
            ),
          );
          break;
        case 3:
          actions.add(FaultAction.bitFlip(0.005 + (rng.nextDouble() * 0.045)));
          break;
        case 4:
          actions.add(FaultAction.reset(atBytes: 50 + rng.nextInt(500)));
          break;
      }
    }
    return actions;
  }
}

/// Closes the connection abruptly after transferring [bytes].
class CutAfterAction extends FaultAction {
  const CutAfterAction(
    this.bytes, {
    this.direction = ProxyDirection.both,
    this.perConnection = false,
  });

  final int bytes;
  final ProxyDirection direction;
  final bool perConnection;
}

/// Adds artificial latency to packets/chunks.
class DelayAction extends FaultAction {
  const DelayAction(
    this.latency, {
    this.direction = ProxyDirection.both,
    this.packetCount,
    this.atBytes,
  });

  final Duration latency;
  final ProxyDirection direction;
  final int? packetCount;
  final int? atBytes;
}

/// Sends the first [maxBytes] then terminates with TCP FIN (or RST if [abrupt]).
class TruncateAction extends FaultAction {
  const TruncateAction(
    this.maxBytes, {
    this.direction = ProxyDirection.both,
    this.abrupt = false,
    this.perConnection = false,
    this.atBytes,
  });

  final int maxBytes;
  final ProxyDirection direction;
  final bool abrupt;
  final bool perConnection;
  final int? atBytes;
}

/// Forcefully resets socket connection.
class ResetAction extends FaultAction {
  const ResetAction({this.atBytes, this.futureConnections = false});

  final int? atBytes;
  final bool futureConnections;
}

/// Flips bits in payload with pseudo-random probability.
class BitFlipAction extends FaultAction {
  const BitFlipAction(
    this.probability, {
    this.direction = ProxyDirection.both,
    this.atBytes,
  });

  final double probability;
  final ProxyDirection direction;
  final int? atBytes;
}

/// Passes traffic through cleanly for [bytes] before faults engage.
class PassThroughAction extends FaultAction {
  const PassThroughAction({this.bytes});

  final int? bytes;
}

/// Manages an active pair of connected sockets (client and upstream server).
class _ConnectionPair {
  _ConnectionPair({
    required this.id,
    required this.clientSocket,
    required this.targetSocket,
  });

  final int id;
  final Socket clientSocket;
  final Socket targetSocket;

  StreamSubscription<Uint8List>? clientSub;
  StreamSubscription<Uint8List>? targetSub;

  bool _clientDone = false;
  bool _targetDone = false;
  bool _isClosed = false;

  int clientToServerBytes = 0;
  int serverToClientBytes = 0;

  bool get isClosed => _isClosed;

  int bytesForDirection(ProxyDirection direction) {
    switch (direction) {
      case ProxyDirection.clientToServer:
        return clientToServerBytes;
      case ProxyDirection.serverToClient:
        return serverToClientBytes;
      case ProxyDirection.both:
        return clientToServerBytes + serverToClientBytes;
    }
  }

  void destroy() {
    if (_isClosed) return;
    _isClosed = true;
    try {
      clientSub?.cancel();
    } catch (_) {}
    try {
      targetSub?.cancel();
    } catch (_) {}
    try {
      clientSocket.destroy();
    } catch (_) {}
    try {
      targetSocket.destroy();
    } catch (_) {}
  }

  void closeDirection(ProxyDirection direction) {
    if (_isClosed) return;
    if (direction == ProxyDirection.clientToServer) {
      _clientDone = true;
      try {
        targetSocket.close();
      } catch (_) {}
    } else if (direction == ProxyDirection.serverToClient) {
      _targetDone = true;
      try {
        clientSocket.close();
      } catch (_) {}
    }
    if (_clientDone && _targetDone) {
      destroy();
    }
  }
}

/// Fault-injecting TCP proxy test harness for Increment 4 (NFR-03).
///
/// Runs a TCP proxy server between a client and a target server port.
/// Operates strictly at the raw TCP stream level so it works transparently
/// with TLS (HTTPS), plain HTTP, and any custom binary protocols.
class FaultyTcpProxy {
  FaultyTcpProxy({
    required this.targetAddress,
    required this.targetPort,
    InternetAddress? bindAddress,
    this.bindPort = 0,
  }) : bindAddress = bindAddress ?? InternetAddress.loopbackIPv4;

  final InternetAddress targetAddress;
  final int targetPort;
  final InternetAddress bindAddress;
  final int bindPort;

  ServerSocket? _serverSocket;
  bool _closed = false;
  int _nextConnectionId = 0;

  final List<_ConnectionPair> _activeConnections = <_ConnectionPair>[];
  final Set<Socket> _pendingSockets = <Socket>{};
  final ProxyStats _stats = ProxyStats();

  // Active fault rules
  CutAfterAction? _cutRule;
  int _cumulativeCutBytes = 0;

  TruncateAction? _truncateRule;
  int _cumulativeTruncateBytes = 0;

  DelayAction? _delayRule;
  int _delayedPacketsCount = 0;
  BitFlipAction? _bitFlipRule;
  ResetAction? _resetRule;
  int _passThroughBytesRemaining = 0;
  bool _resetOnConnect = false;

  Random _random = Random();
  int? _currentSeed;
  List<FaultAction> _scheduleActions = <FaultAction>[];

  /// Starts and binds a new [FaultyTcpProxy].
  static Future<FaultyTcpProxy> start({
    required dynamic targetAddress,
    required int targetPort,
    InternetAddress? bindAddress,
    int bindPort = 0,
  }) async {
    final InternetAddress targetAddr;
    if (targetAddress is InternetAddress) {
      targetAddr = targetAddress;
    } else if (targetAddress is String) {
      targetAddr =
          InternetAddress.tryParse(targetAddress) ??
          (await InternetAddress.lookup(targetAddress)).first;
    } else {
      throw ArgumentError.value(
        targetAddress,
        'targetAddress',
        'Must be InternetAddress or String',
      );
    }

    final proxy = FaultyTcpProxy(
      targetAddress: targetAddr,
      targetPort: targetPort,
      bindAddress: bindAddress,
      bindPort: bindPort,
    );
    await proxy.startListening();
    return proxy;
  }

  /// Binds the listening server socket.
  Future<void> startListening() async {
    if (_serverSocket != null) return;
    _serverSocket = await ServerSocket.bind(bindAddress, bindPort);
    _serverSocket!.listen(
      _handleIncomingConnection,
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  /// Port on which this proxy is listening.
  int get port {
    final ss = _serverSocket;
    if (ss == null) {
      throw StateError('FaultyTcpProxy has not been started');
    }
    return ss.port;
  }

  /// Address on which this proxy is listening.
  InternetAddress get address {
    final ss = _serverSocket;
    if (ss == null) {
      throw StateError('FaultyTcpProxy has not been started');
    }
    return ss.address;
  }

  /// Total bytes forwarded across all connections.
  int get totalBytesForwarded => _stats.totalBytesForwarded;

  /// Total packets delayed by artificial latency.
  int get packetsDelayed => _stats.packetsDelayed;

  /// Total faults triggered.
  int get faultsTriggered => _stats.faultsTriggered;

  /// Current proxy statistics.
  ProxyStats get stats => _stats;

  /// Active seed, if configured.
  int? get currentSeed => _currentSeed;

  /// Number of currently active connection pairs.
  int get activeConnectionCount => _activeConnections.length;

  /// Whether the proxy has been closed.
  bool get isClosed => _closed;

  /// List of actions in the current schedule.
  List<FaultAction> get currentSchedule =>
      List<FaultAction>.unmodifiable(_scheduleActions);

  // ---------------------------------------------------------------------------
  // Fault injection modes
  // ---------------------------------------------------------------------------

  /// Closes the connection abruptly after transferring [bytes].
  ///
  /// If [perConnection] is false (the default), the budget applies to cumulative
  /// bytes across the proxy. If [direction] is specified, only bytes in that
  /// direction count towards the threshold.
  void cutAfter(
    int bytes, {
    ProxyDirection direction = ProxyDirection.both,
    bool perConnection = false,
  }) {
    _cutRule = CutAfterAction(
      bytes,
      direction: direction,
      perConnection: perConnection,
    );
    _cumulativeCutBytes = 0;
  }

  /// Adds artificial latency to chunks/packets.
  ///
  /// If [packetCount] is provided, only that number of chunks will be delayed.
  void delay(
    Duration latency, {
    ProxyDirection direction = ProxyDirection.both,
    int? packetCount,
  }) {
    _delayRule = DelayAction(
      latency,
      direction: direction,
      packetCount: packetCount,
    );
    _delayedPacketsCount = 0;
  }

  /// Sends first [maxBytes] then terminates with TCP FIN (or RST if [abrupt]).
  void truncate(
    int maxBytes, {
    ProxyDirection direction = ProxyDirection.both,
    bool abrupt = false,
    bool perConnection = false,
  }) {
    _truncateRule = TruncateAction(
      maxBytes,
      direction: direction,
      abrupt: abrupt,
      perConnection: perConnection,
    );
    _cumulativeTruncateBytes = 0;
  }

  /// Forcefully resets all active socket connections (`SocketDirection.both` destroy).
  ///
  /// If [futureConnections] is true, subsequent incoming connections will also
  /// be reset immediately upon arrival.
  void resetConnection({bool futureConnections = false}) {
    _stats.faultsTriggered++;
    _resetOnConnect = futureConnections;
    for (final s in List<Socket>.of(_pendingSockets)) {
      try {
        s.destroy();
      } catch (_) {}
    }
    _pendingSockets.clear();
    for (final conn in List<_ConnectionPair>.of(_activeConnections)) {
      _stats.connectionsClosed++;
      conn.destroy();
    }
    _activeConnections.clear();
  }

  /// Flips bits in stream payload with seeded randomness.
  ///
  /// [probability] defines the probability (0.0 to 1.0) that a given byte
  /// will have a bit flipped. If [seed] is provided, deterministic randomness
  /// is used.
  void bitFlip(
    double probability, {
    int? seed,
    ProxyDirection direction = ProxyDirection.both,
  }) {
    if (probability < 0.0 || probability > 1.0) {
      throw ArgumentError.value(
        probability,
        'probability',
        'Must be between 0.0 and 1.0',
      );
    }
    if (seed != null) {
      _currentSeed = seed;
      _random = Random(seed);
    }
    _bitFlipRule = BitFlipAction(probability, direction: direction);
  }

  /// Configures a deterministic sequence of faults replayable by [seed].
  ///
  /// Actions may include delays, bit flips, cuts, truncations, and pass-throughs.
  void seededFaultSchedule(int seed, List<FaultAction> actions) {
    resetFaults();
    _currentSeed = seed;
    _random = Random(seed);
    _scheduleActions = List<FaultAction>.of(actions);

    for (final action in actions) {
      switch (action) {
        case CutAfterAction():
          _cutRule = action;
          _cumulativeCutBytes = 0;
          break;
        case DelayAction():
          _delayRule = action;
          break;
        case TruncateAction():
          _truncateRule = action;
          _cumulativeTruncateBytes = 0;
          break;
        case ResetAction():
          if (action.atBytes == null) {
            _resetOnConnect = action.futureConnections;
            if (!action.futureConnections) {
              resetConnection();
            }
          } else {
            _resetRule = action;
          }
          break;
        case BitFlipAction():
          _bitFlipRule = action;
          break;
        case PassThroughAction():
          _passThroughBytesRemaining = action.bytes ?? 0;
          break;
      }
    }
  }

  /// Clears all fault injection rules, returning to transparent pass-through.
  void resetFaults() {
    _cutRule = null;
    _cumulativeCutBytes = 0;
    _truncateRule = null;
    _cumulativeTruncateBytes = 0;
    _delayRule = null;
    _delayedPacketsCount = 0;
    _bitFlipRule = null;
    _resetRule = null;
    _passThroughBytesRemaining = 0;
    _resetOnConnect = false;
    _scheduleActions.clear();
  }

  /// Resets statistics tracking counters to zero.
  void resetStats() {
    _stats.reset();
  }

  /// Closes the proxy server and terminates all active connections.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final ss = _serverSocket;
    _serverSocket = null;
    if (ss != null) {
      try {
        await ss.close();
      } catch (_) {}
    }
    for (final s in List<Socket>.of(_pendingSockets)) {
      try {
        s.destroy();
      } catch (_) {}
    }
    _pendingSockets.clear();
    for (final conn in List<_ConnectionPair>.of(_activeConnections)) {
      _stats.connectionsClosed++;
      conn.destroy();
    }
    _activeConnections.clear();
  }

  /// Alias for [close].
  Future<void> stop() => close();

  // ---------------------------------------------------------------------------
  // Internal connection handling
  // ---------------------------------------------------------------------------

  Future<void> _handleIncomingConnection(Socket clientSocket) async {
    unawaited(clientSocket.done.catchError((Object _) {}));

    if (_closed) {
      clientSocket.destroy();
      return;
    }

    if (_resetOnConnect) {
      _stats.faultsTriggered++;
      clientSocket.destroy();
      return;
    }

    _stats.connectionsAccepted++;
    _pendingSockets.add(clientSocket);

    Socket targetSocket;
    try {
      targetSocket = await Socket.connect(targetAddress, targetPort);
      unawaited(targetSocket.done.catchError((Object _) {}));
    } catch (_) {
      _pendingSockets.remove(clientSocket);
      _stats.faultsTriggered++;
      _stats.connectionsClosed++;
      clientSocket.destroy();
      return;
    } finally {
      _pendingSockets.remove(clientSocket);
    }

    if (_closed) {
      clientSocket.destroy();
      targetSocket.destroy();
      return;
    }

    final pair = _ConnectionPair(
      id: ++_nextConnectionId,
      clientSocket: clientSocket,
      targetSocket: targetSocket,
    );
    _activeConnections.add(pair);

    _pipe(pair, clientSocket, targetSocket, ProxyDirection.clientToServer);
    _pipe(pair, targetSocket, clientSocket, ProxyDirection.serverToClient);
  }

  void _pipe(
    _ConnectionPair pair,
    Socket sourceSocket,
    Socket destSocket,
    ProxyDirection direction,
  ) {
    StreamSubscription<Uint8List>? sub;
    sub = sourceSocket.listen(
      (chunk) {
        sub?.pause();
        _handleChunk(pair, chunk, sourceSocket, destSocket, direction)
            .then((_) {
              if (!pair.isClosed && !_closed) {
                sub?.resume();
              }
            })
            .catchError((Object _) {
              _removePair(pair);
            });
      },
      onError: (Object _) {
        _removePair(pair);
      },
      onDone: () {
        _handleSourceDone(pair, destSocket, direction);
      },
      cancelOnError: true,
    );

    if (direction == ProxyDirection.clientToServer) {
      pair.clientSub = sub;
    } else {
      pair.targetSub = sub;
    }
  }

  void _removePair(_ConnectionPair pair) {
    if (_activeConnections.remove(pair)) {
      _stats.connectionsClosed++;
    }
    pair.destroy();
  }

  void _handleSourceDone(
    _ConnectionPair pair,
    Socket destSocket,
    ProxyDirection direction,
  ) {
    pair.closeDirection(direction);
    if (pair.isClosed) {
      _removePair(pair);
    }
  }

  Future<void> _handleChunk(
    _ConnectionPair pair,
    Uint8List chunk,
    Socket sourceSocket,
    Socket destSocket,
    ProxyDirection direction,
  ) async {
    if (pair.isClosed || _closed || chunk.isEmpty) return;

    // Check pass-through phase
    if (_passThroughBytesRemaining > 0) {
      if (chunk.length <= _passThroughBytesRemaining) {
        _passThroughBytesRemaining -= chunk.length;
        destSocket.add(chunk);
        await destSocket.flush();
        _recordBytes(pair, chunk.length, direction);
        return;
      } else {
        final passChunk = chunk.sublist(0, _passThroughBytesRemaining);
        final remChunk = chunk.sublist(_passThroughBytesRemaining);
        _passThroughBytesRemaining = 0;
        destSocket.add(passChunk);
        await destSocket.flush();
        _recordBytes(pair, passChunk.length, direction);
        await _handleChunk(pair, remChunk, sourceSocket, destSocket, direction);
        return;
      }
    }

    // Check Reset rule with byte threshold
    final resetRule = _resetRule;
    if (resetRule != null && resetRule.atBytes != null) {
      if (_stats.totalBytesForwarded + chunk.length >= resetRule.atBytes!) {
        _stats.faultsTriggered++;
        _removePair(pair);
        return;
      }
    }

    // Check CutAfter rule
    final cutRule = _cutRule;
    if (cutRule != null && cutRule.direction.matches(direction)) {
      final current = cutRule.perConnection
          ? pair.bytesForDirection(cutRule.direction)
          : _cumulativeCutBytes;
      final threshold = cutRule.bytes;

      if (current >= threshold) {
        _stats.faultsTriggered++;
        _removePair(pair);
        return;
      }

      if (current + chunk.length >= threshold) {
        final allowed = threshold - current;
        var toSend = allowed > 0 ? chunk.sublist(0, allowed) : Uint8List(0);
        toSend = _applyBitFlip(toSend, direction);
        await _applyDelay(direction);
        if (pair.isClosed || _closed) return;

        if (toSend.isNotEmpty) {
          try {
            destSocket.add(toSend);
            await destSocket.flush();
            _recordBytes(pair, toSend.length, direction);
            _cumulativeCutBytes += toSend.length;
          } catch (_) {
            _removePair(pair);
            return;
          }
        }
        _stats.faultsTriggered++;
        _removePair(pair);
        return;
      }
    }

    // Check Truncate rule
    final truncRule = _truncateRule;
    if (truncRule != null && truncRule.direction.matches(direction)) {
      final current = truncRule.perConnection
          ? pair.bytesForDirection(truncRule.direction)
          : _cumulativeTruncateBytes;
      final threshold = truncRule.maxBytes;

      if (current >= threshold) {
        _stats.faultsTriggered++;
        if (truncRule.abrupt) {
          _removePair(pair);
        } else {
          pair.closeDirection(direction);
        }
        return;
      }

      if (current + chunk.length >= threshold) {
        final allowed = threshold - current;
        var toSend = allowed > 0 ? chunk.sublist(0, allowed) : Uint8List(0);
        toSend = _applyBitFlip(toSend, direction);
        await _applyDelay(direction);
        if (pair.isClosed || _closed) return;

        if (toSend.isNotEmpty) {
          try {
            destSocket.add(toSend);
            await destSocket.flush();
            _recordBytes(pair, toSend.length, direction);
            _cumulativeTruncateBytes += toSend.length;
          } catch (_) {
            _removePair(pair);
            return;
          }
        }
        _stats.faultsTriggered++;
        if (truncRule.abrupt) {
          _removePair(pair);
        } else {
          pair.closeDirection(direction);
        }
        return;
      }
    }

    // Normal forwarding path with bitFlip and delay
    final toSend = _applyBitFlip(chunk, direction);
    await _applyDelay(direction);
    if (pair.isClosed || _closed) return;

    try {
      destSocket.add(toSend);
      await destSocket.flush();
      _recordBytes(pair, toSend.length, direction);
      _cumulativeCutBytes += toSend.length;
      _cumulativeTruncateBytes += toSend.length;
    } catch (_) {
      _removePair(pair);
    }
  }

  Uint8List _applyBitFlip(Uint8List data, ProxyDirection direction) {
    if (data.isEmpty) return data;
    final rule = _bitFlipRule;
    if (rule == null || !rule.direction.matches(direction)) return data;
    if (rule.probability <= 0.0) return data;

    final copy = Uint8List.fromList(data);
    var flipped = false;

    for (var i = 0; i < copy.length; i++) {
      if (_random.nextDouble() < rule.probability) {
        final bit = _random.nextInt(8);
        copy[i] ^= (1 << bit);
        flipped = true;
      }
    }

    if (flipped) {
      _stats.faultsTriggered++;
    }
    return copy;
  }

  Future<void> _applyDelay(ProxyDirection direction) async {
    final rule = _delayRule;
    if (rule == null || !rule.direction.matches(direction)) return;
    if (rule.latency == Duration.zero) return;

    if (rule.packetCount != null && _delayedPacketsCount >= rule.packetCount!) {
      return;
    }

    _delayedPacketsCount++;
    _stats.packetsDelayed++;
    await Future<void>.delayed(rule.latency);
  }

  void _recordBytes(_ConnectionPair pair, int bytes, ProxyDirection direction) {
    _stats.totalBytesForwarded += bytes;
    if (direction == ProxyDirection.clientToServer) {
      _stats.clientToServerBytes += bytes;
      pair.clientToServerBytes += bytes;
    } else {
      _stats.serverToClientBytes += bytes;
      pair.serverToClientBytes += bytes;
    }
  }
}
