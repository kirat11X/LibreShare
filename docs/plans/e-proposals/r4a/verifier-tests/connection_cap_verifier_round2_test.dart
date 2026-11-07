// VERIFIER round-2 probes for E5 / R4a (handshake timeout, stop(force) mid-handshake). Companion of
// connection_cap_verifier_probes_test.dart; same helpers. Original header follows.
// VERIFIER probes for E5 / R4a (written by the verifier, a different agent from the tester and the
// coder). They exercise what the wrapper must not break: remote-address keyed state (PinGuard,
// rate limiter), slot accounting under abandoned TLS handshakes and connection churn, a big chunk
// PUT beside idle sockets, repeated stop()/start() on one port, and the peer certificate.
//
// Labels: P1 PinGuard key, P2 rate limiter, P3 abandoned handshakes, P4 churn, P5 big chunk,
// P6 stop/start, X1 remote address seen by handler (plain + TLS), X2 peer certificate forwarded,
// X3 half-closing client (slot released while the socket is still open), X4 stop(force) with a
// stalled handshake.
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/server/capped_server_socket.dart';
import 'package:test/test.dart';

import '../helpers/p3_secure_handler.dart';
import '../helpers/p3_secure_rig.dart';

/// Opens [n] raw TCP connections from [from]; returns how many are still open after [wait].
Future<int> _openAndCount(
  int port,
  int n, {
  String from = '127.0.0.1',
  Duration wait = const Duration(milliseconds: 500),
}) async {
  final socks = <Socket>[];
  final closed = <bool>[];
  for (var i = 0; i < n; i++) {
    try {
      final s = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        sourceAddress: InternetAddress(from),
        timeout: const Duration(seconds: 3),
      );
      final idx = closed.length;
      closed.add(false);
      socks.add(s);
      s.listen(
        (_) {},
        onDone: () => closed[idx] = true,
        onError: (Object _) => closed[idx] = true,
        cancelOnError: true,
      );
    } on SocketException {
      closed.add(true);
    }
  }
  await Future<void>.delayed(wait);
  final open = closed.where((c) => !c).length;
  for (final s in socks) {
    s.destroy();
  }
  // let the server notice the closes before the next measurement
  await Future<void>.delayed(const Duration(milliseconds: 150));
  return open;
}

Future<int> _httpsStatus(int port, String path) async {
  final c = HttpClient(context: buildClientContext())
    ..badCertificateCallback = (_, _, _) => true;
  try {
    final req = await c.getUrl(Uri.parse('https://127.0.0.1:$port$path'));
    final res = await req.close().timeout(const Duration(seconds: 5));
    await res.drain<void>();
    return res.statusCode;
  } finally {
    c.close(force: true);
  }
}

ApiServer _tlsServer({
  int total = 64,
  int perIp = 16,
  int port = 0,
  P3SecureHandler? handler,
  Duration? hsTimeout,
}) => ApiServer(
  handler: handler ?? P3SecureHandler(),
  tlsHandshakeTimeout: hsTimeout ?? kDefaultHandshakeTimeout,
  security: SecurityConfig.tls(
    identity: p3ServerKey,
    trust: InMemoryTrustStore(),
  ),
  bindAddress: InternetAddress.loopbackIPv4,
  preferredPort: port,
  maxPortFallback: port,
  enableRateLimit: false,
  maxConnections: total,
  maxConnectionsPerIp: perIp,
);

void main() {
  /// A client that sends a TLS record header and then nothing; `closed` completes when the server
  /// side closes the TCP connection (or resets it).
  Future<(Socket, Future<bool> Function(Duration))> stalledClient(
    int port,
  ) async {
    final s = await Socket.connect('127.0.0.1', port);
    final closed = Completer<void>();
    s.listen(
      (_) {},
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
      onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      },
    );
    s.add([0x16, 0x03, 0x01, 0x02, 0x00]);
    await s.flush();
    Future<bool> sawClose(Duration t) async {
      try {
        await closed.future.timeout(t);
        return true;
      } on TimeoutException {
        return false;
      }
    }

    return (s, sawClose);
  }

  test('X4 stop(force: true) closes a socket that is stalled in the TLS handshake (client sees the close within 3 s)', () async {
    final server = _tlsServer();
    final port = await server.start();
    final (stalled, sawClose) = await stalledClient(port);
    addTearDown(stalled.destroy);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await server.stop(force: true);
    final closed = await sawClose(const Duration(seconds: 3));
    // ignore: avoid_print
    print('X4 stalled-handshake socket closed by stop(force): $closed');
    expect(closed, isTrue);
  });

  test('X5 default 10 s handshake timeout frees the slots of stalled TLS handshakes (checked at 12.5 s)', () async {
    final server = _tlsServer(total: 8, perIp: 2);
    final port = await server.start();
    addTearDown(() => server.stop(force: true));
    final stalled = <Socket>[];
    for (var i = 0; i < 2; i++) {
      final (s, _) = await stalledClient(port);
      stalled.add(s);
    }
    await Future<void>.delayed(const Duration(seconds: 5));
    final held = await _openAndCount(
      port,
      1,
      wait: const Duration(milliseconds: 300),
    );
    expect(
      held,
      0,
      reason: 'at 5 s the slots must still be held (timeout is 10 s)',
    );
    await Future<void>.delayed(const Duration(milliseconds: 7000));
    final open = await _openAndCount(
      port,
      2,
      wait: const Duration(milliseconds: 300),
    );
    // ignore: avoid_print
    print(
      'X5 at ~12.5 s two new sockets of the same IP stay open: $open (2 = slots free)',
    );
    for (final s in stalled) {
      s.destroy();
    }
    expect(open, 2);
  });

  test('X5b handshake timeout 1 s: the stalled TCP connection is really closed (client sees EOF), not only uncounted', () async {
    final server = _tlsServer(
      total: 8,
      perIp: 2,
      hsTimeout: const Duration(seconds: 1),
    );
    final port = await server.start();
    addTearDown(() => server.stop(force: true));
    final (stalled, sawClose) = await stalledClient(port);
    addTearDown(stalled.destroy);
    final closed = await sawClose(const Duration(seconds: 4));
    // ignore: avoid_print
    print(
      'X5b client saw the server close within 4 s of a 1 s timeout: $closed',
    );
    expect(closed, isTrue);
  });

  test('X6 handshake timeout 1 s frees the slots within 3 s', () async {
    final server = _tlsServer(
      total: 8,
      perIp: 2,
      hsTimeout: const Duration(seconds: 1),
    );
    final port = await server.start();
    addTearDown(() => server.stop(force: true));
    final stalled = <Socket>[];
    for (var i = 0; i < 2; i++) {
      stalled.add((await stalledClient(port)).$1);
    }
    expect(
      await _openAndCount(port, 1, wait: const Duration(milliseconds: 300)),
      0,
    );
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    final open = await _openAndCount(
      port,
      2,
      wait: const Duration(milliseconds: 300),
    );
    for (final s in stalled) {
      s.destroy();
    }
    expect(open, 2);
  });

  test('X7 handshake timeout 1 s does not hurt a normal client (HTTPS GET /info = 200, 10 times)', () async {
    final server = _tlsServer(hsTimeout: const Duration(seconds: 1));
    final port = await server.start();
    addTearDown(() => server.stop(force: true));
    for (var i = 0; i < 10; i++) {
      expect(await _httpsStatus(port, '$kApiPrefix/info'), 200);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    // after the timeout moment a late timer must not have killed live connections
    expect(await _httpsStatus(port, '$kApiPrefix/info'), 200);
  });

  test('X8 fd leak check: 6 waves of 4 stalled handshakes (per-IP 4, timeout 1 s) leave at most a handful of server-side sockets', () async {
    final server = _tlsServer(
      total: 16,
      perIp: 4,
      hsTimeout: const Duration(seconds: 1),
    );
    final port = await server.start();
    addTearDown(() => server.stop(force: true));
    final clients = <Socket>[];
    var sawCloseCount = 0;
    for (var wave = 0; wave < 6; wave++) {
      final waveClients = <Future<bool> Function(Duration)>[];
      for (var i = 0; i < 4; i++) {
        final (s, sc) = await stalledClient(port);
        clients.add(s);
        waveClients.add(sc);
      }
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      for (final sc in waveClients) {
        if (await sc(const Duration(milliseconds: 50))) sawCloseCount++;
      }
    }
    // ignore: avoid_print
    print(
      'X8 of 24 stalled client connections the server closed: $sawCloseCount',
    );
    for (final s in clients) {
      s.destroy();
    }
    expect(sawCloseCount, greaterThanOrEqualTo(20));
  });
}
