// VERIFIER round-3 attack tests for E5 / R4a (written by the verifier, not by tester or coder):
// the phase-1 gate (whole first TLS record within the handshake timeout, then secureServer with
// bufferedData) and the slot accounting around it.
//   R1 one byte per 400 ms inside the first record      R2 oversize / lying record length
//   R3 ClientHello trickled in 1-byte packets (legit)   R4 connect and send nothing
//   R5 complete ClientHello, then stall (phase 2): bounded by the caps, never uncounted
//   R6 real pinned ApiClient, with 0 / 100 ms latency   R7 stop(force) while handshaking
//   R8 non-TLS first byte is dropped at once
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/server/capped_server_socket.dart';
import 'package:test/test.dart';

import '../helpers/p3_secure_handler.dart';
import '../helpers/p3_secure_rig.dart';

ApiServer _tlsServer({
  int total = 64,
  int perIp = 16,
  int port = 0,
  Duration? hsTimeout,
}) => ApiServer(
  handler: P3SecureHandler(
    info: DeviceInfo(
      deviceId: p3ServerKey.identity.deviceId,
      alias: 'Receiver',
      platform: 'linux',
      port: 53318,
      fingerprint: p3ServerKey.identity.fingerprint,
      version: kProtocolVersionSecure,
    ),
  ),
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
  tlsHandshakeTimeout: hsTimeout ?? kDefaultHandshakeTimeout,
);

/// A raw client; [closedAt] completes with the elapsed time when the server closed the connection.
class _Raw {
  _Raw._(this.socket) {
    socket.listen(
      (_) {},
      onDone: _mark,
      onError: (Object _) => _mark(),
      cancelOnError: true,
    );
  }

  static Future<_Raw> open(int port) async =>
      _Raw._(await Socket.connect('127.0.0.1', port));

  final Socket socket;
  final Stopwatch clock = Stopwatch()..start();
  final Completer<Duration> closedAt = Completer<Duration>();

  void _mark() {
    if (!closedAt.isCompleted) closedAt.complete(clock.elapsed);
  }

  /// The elapsed time at which the server closed, or null if still open after [t].
  Future<Duration?> closesWithin(Duration t) async {
    try {
      return await closedAt.future.timeout(t);
    } on TimeoutException {
      return null;
    }
  }

  void destroy() => socket.destroy();
}

/// How many of [n] new sockets from 127.0.0.1 are still open after [wait] (all are closed after).
Future<int> _openAndCount(
  int port,
  int n, {
  Duration wait = const Duration(milliseconds: 400),
}) async {
  final socks = <_Raw>[];
  for (var i = 0; i < n; i++) {
    socks.add(await _Raw.open(port));
  }
  await Future<void>.delayed(wait);
  final open = socks.where((s) => !s.closedAt.isCompleted).length;
  for (final s in socks) {
    s.destroy();
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
  return open;
}

/// A real TLS client through a stall-after-ClientHello proxy: the server gets a complete
/// ClientHello and then silence (phase 2). Null if the client side could not even connect.
Future<Socket?> _helloThenSilence(int proxyPort) async {
  try {
    return await SecureSocket.connect(
      '127.0.0.1',
      proxyPort,
      context: buildClientContext(),
      onBadCertificate: (_) => true,
    ).timeout(const Duration(seconds: 3));
  } on Object {
    return null;
  }
}

const _recordHeader512 = [0x16, 0x03, 0x01, 0x02, 0x00];

/// TCP proxy between a client and the server under test. Options: [delay] per chunk and direction
/// (latency), [trickle] = forward the first N client bytes one byte per packet,
/// [stallAfterRecord] = forward exactly the first TLS record (the ClientHello) and swallow the
/// rest of what the client sends (the connection stays open both ways).
class _Proxy {
  _Proxy._(this._server, this._upstream, this.delay, this.trickle, this.stall);

  static Future<_Proxy> start(
    int upstream, {
    Duration delay = Duration.zero,
    int trickle = 0,
    bool stallAfterRecord = false,
  }) async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = _Proxy._(s, upstream, delay, trickle, stallAfterRecord);
    s.listen(p._handle);
    return p;
  }

  final ServerSocket _server;
  final int _upstream;
  final Duration delay;
  final int trickle;
  final bool stall;
  final List<Socket> _all = [];
  int upstreamClosedByServer = 0;
  int get port => _server.port;

  Future<void> _handle(Socket c) async {
    final Socket u;
    try {
      u = await Socket.connect('127.0.0.1', _upstream);
    } on Object {
      c.destroy();
      return;
    }
    _all
      ..add(c)
      ..add(u);
    c.setOption(SocketOption.tcpNoDelay, true);
    u.setOption(SocketOption.tcpNoDelay, true);
    // server -> client
    unawaited(
      u
          .asyncMap((d) async {
            if (delay > Duration.zero) await Future<void>.delayed(delay);
            return d;
          })
          .listen(
            c.add,
            onDone: () {
              upstreamClosedByServer++;
              c.destroy();
            },
            onError: (Object _) {
              upstreamClosedByServer++;
              c.destroy();
            },
          )
          .asFuture<void>()
          .catchError((Object _) {}),
    );
    // client -> server
    var sent = 0;
    final head = BytesBuilder();
    int? recordEnd;
    try {
      await for (final d in c) {
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        for (var i = 0; i < d.length;) {
          if (stall && recordEnd != null && sent >= recordEnd) {
            i = d.length; // swallow
            continue;
          }
          if (sent < trickle) {
            u.add([d[i]]);
            await u.flush();
            await Future<void>.delayed(const Duration(milliseconds: 1));
            sent++;
            i++;
          } else {
            var end = d.length;
            if (stall && recordEnd != null) {
              end = i + (recordEnd - sent).clamp(0, d.length - i);
            }
            u.add(d.sublist(i, end));
            sent += end - i;
            i = end;
          }
          if (stall && recordEnd == null && sent >= 5) {
            // record length is known once 5 bytes went out; they are in `d` (first packet)
            head.add(d.sublist(0, d.length < 5 ? d.length : 5));
          }
        }
        if (stall && recordEnd == null && head.length >= 5) {
          final h = head.toBytes();
          recordEnd = 5 + ((h[3] << 8) | h[4]);
        }
      }
    } on Object {
      // client went away
    }
    u.destroy();
  }

  Future<void> close() async {
    for (final s in _all) {
      s.destroy();
    }
    await _server.close();
  }
}

void main() {
  group(
    'R1-R4, R8: the gate refuses slow, lying, silent and non-TLS clients',
    () {
      test('R1 one byte per 400 ms inside the first record: closed by the 2 s timeout, slot freed', () async {
        final server = _tlsServer(
          total: 8,
          perIp: 2,
          hsTimeout: const Duration(seconds: 2),
        );
        final port = await server.start();
        addTearDown(() => server.stop(force: true));
        final c = await _Raw.open(port);
        c.socket.add(_recordHeader512);
        await c.socket.flush();
        final trickler = Timer.periodic(const Duration(milliseconds: 400), (t) {
          try {
            c.socket.add([0x01]);
          } on Object {
            t.cancel();
          }
        });
        addTearDown(trickler.cancel);
        final at = await c.closesWithin(const Duration(seconds: 4));
        trickler.cancel();
        // ignore: avoid_print
        print('R1 server closed the trickling client after: $at');
        expect(
          at,
          isNotNull,
          reason: 'a 1-byte-per-400ms record must not hold the slot',
        );
        expect(at!, lessThan(const Duration(milliseconds: 3200)));
        c.destroy();
        expect(
          await _openAndCount(port, 3),
          2,
          reason: 'slot must be free again',
        );
      });

      test('R2a record length 0xFFFF (lie / oversize): dropped at once, not after the timeout', () async {
        final server = _tlsServer(
          total: 8,
          perIp: 2,
          hsTimeout: const Duration(seconds: 8),
        );
        final port = await server.start();
        addTearDown(() => server.stop(force: true));
        final c = await _Raw.open(port);
        c.socket.add([0x16, 0x03, 0x01, 0xFF, 0xFF]);
        await c.socket.flush();
        final at = await c.closesWithin(const Duration(seconds: 2));
        // ignore: avoid_print
        print('R2a oversize record closed after: $at');
        expect(at, isNotNull);
        expect(await _openAndCount(port, 3), 2);
      });

      test('R2b record of length 0 (complete but empty): handshake fails fast, connection closed, slot freed', () async {
        final server = _tlsServer(
          total: 8,
          perIp: 2,
          hsTimeout: const Duration(seconds: 8),
        );
        final port = await server.start();
        addTearDown(() => server.stop(force: true));
        final c = await _Raw.open(port);
        c.socket.add([0x16, 0x03, 0x01, 0x00, 0x00]);
        await c.socket.flush();
        final at = await c.closesWithin(const Duration(seconds: 3));
        // ignore: avoid_print
        print('R2b empty record closed after: $at');
        expect(at, isNotNull);
        expect(await _openAndCount(port, 3), 2);
      });

      test('R2d a complete record that only CLAIMS a long ClientHello (type 1, handshake length 500, 4 payload bytes) is dropped quickly', () async {
        final server = _tlsServer(
          total: 8,
          perIp: 2,
          hsTimeout: const Duration(seconds: 8),
        );
        final port = await server.start();
        addTearDown(() => server.stop(force: true));
        final c = await _Raw.open(port);
        // record header (handshake, TLS 1.0, length 4) + handshake header (ClientHello, length 500)
        c.socket.add([0x16, 0x03, 0x01, 0x00, 0x04, 0x01, 0x00, 0x01, 0xF4]);
        await c.socket.flush();
        final at = await c.closesWithin(const Duration(seconds: 3));
        // ignore: avoid_print
        print('R2d truncated-ClientHello record closed after: $at');
        expect(
          at,
          isNotNull,
          reason:
              'a 9-byte message must not hold a slot until the client closes',
        );
        expect(await _openAndCount(port, 3), 2);
      });

      test('R2c record length 16640 (the bound) sent in full with garbage: not hanging, closed, slot freed', () async {
        final server = _tlsServer(
          total: 8,
          perIp: 2,
          hsTimeout: const Duration(seconds: 3),
        );
        final port = await server.start();
        addTearDown(() => server.stop(force: true));
        final c = await _Raw.open(port);
        final rec = Uint8List(5 + 16640)
          ..setRange(0, 5, [0x16, 0x03, 0x01, 0x41, 0x00]);
        c.socket.add(rec);
        await c.socket.flush();
        final at = await c.closesWithin(const Duration(seconds: 5));
        // ignore: avoid_print
        print('R2c full 16640-byte garbage record closed after: $at');
        expect(at, isNotNull);
        expect(await _openAndCount(port, 3), 2);
      });

      test('R4 a client that connects and sends nothing is closed at the timeout (1.5 s), slot freed', () async {
        final server = _tlsServer(
          total: 8,
          perIp: 2,
          hsTimeout: const Duration(milliseconds: 1500),
        );
        final port = await server.start();
        addTearDown(() => server.stop(force: true));
        final c = await _Raw.open(port);
        final at = await c.closesWithin(const Duration(seconds: 4));
        // ignore: avoid_print
        print('R4 silent client closed after: $at');
        expect(at, isNotNull);
        expect(at!, greaterThan(const Duration(milliseconds: 1200)));
        expect(await _openAndCount(port, 3), 2);
      });

      test('R8 a non-TLS first byte (plain HTTP on the TLS port) is dropped at once, not after the timeout', () async {
        final server = _tlsServer(
          total: 8,
          perIp: 2,
          hsTimeout: const Duration(seconds: 8),
        );
        final port = await server.start();
        addTearDown(() => server.stop(force: true));
        final c = await _Raw.open(port);
        c.socket.write('GET /api/v1/info HTTP/1.1\r\nHost: x\r\n\r\n');
        await c.socket.flush();
        final at = await c.closesWithin(const Duration(seconds: 2));
        // ignore: avoid_print
        print('R8 plain HTTP on TLS port closed after: $at');
        expect(at, isNotNull, reason: 'must not wait for the 8 s timeout');
        expect(await _openAndCount(port, 3), 2);
      });
    },
  );

  group('R3, R6: legitimate TLS clients are not hurt', () {
    Future<String> apiInfo(int port) async {
      final me = p3Alice.key;
      final client = ApiClient(
        host: '127.0.0.1',
        port: port,
        security: SecurityConfig.tls(identity: me, trust: InMemoryTrustStore()),
        expectedFingerprint: p3ServerKey.identity.fingerprint,
        requestTimeout: const Duration(seconds: 10),
        connectTimeout: const Duration(seconds: 5),
      );
      try {
        return (await client.info()).deviceId;
      } finally {
        client.close();
      }
    }

    test('R6a real pinned ApiClient, direct', () async {
      final server = _tlsServer();
      final port = await server.start();
      addTearDown(() => server.stop(force: true));
      expect(await apiInfo(port), p3ServerKey.identity.deviceId);
    });

    test('R6b real pinned ApiClient through a 100 ms-per-direction latency proxy (default timeout)', () async {
      final server = _tlsServer();
      final port = await server.start();
      addTearDown(() => server.stop(force: true));
      final proxy = await _Proxy.start(
        port,
        delay: const Duration(milliseconds: 100),
      );
      addTearDown(proxy.close);
      final sw = Stopwatch()..start();
      expect(await apiInfo(proxy.port), p3ServerKey.identity.deviceId);
      // ignore: avoid_print
      print(
        'R6b ApiClient.info() with 100 ms latency took ${sw.elapsedMilliseconds} ms',
      );
    });

    test('R6c 100 ms latency and a 1.5 s handshake timeout: still fine (timeout counts the first record only)', () async {
      final server = _tlsServer(hsTimeout: const Duration(milliseconds: 1500));
      final port = await server.start();
      addTearDown(() => server.stop(force: true));
      final proxy = await _Proxy.start(
        port,
        delay: const Duration(milliseconds: 100),
      );
      addTearDown(proxy.close);
      for (var i = 0; i < 3; i++) {
        expect(await apiInfo(proxy.port), p3ServerKey.identity.deviceId);
      }
    });

    test('R3 ClientHello split into 1-byte packets (first 600 bytes): real ApiClient still handshakes', () async {
      final server = _tlsServer();
      final port = await server.start();
      addTearDown(() => server.stop(force: true));
      final proxy = await _Proxy.start(port, trickle: 600);
      addTearDown(proxy.close);
      expect(await apiInfo(proxy.port), p3ServerKey.identity.deviceId);
    });
  });

  group('R5, R7: a complete ClientHello followed by silence (phase 2)', () {
    test('R5 stalled-after-ClientHello sockets keep their slots (counted), so the attacker is bounded by the per-IP cap', () async {
      final server = _tlsServer(
        total: 16,
        perIp: 4,
        hsTimeout: const Duration(seconds: 1),
      );
      final port = await server.start();
      addTearDown(() => server.stop(force: true));
      final proxy = await _Proxy.start(port, stallAfterRecord: true);
      addTearDown(proxy.close);
      final attackers = <Socket>[];
      for (var i = 0; i < 4; i++) {
        final c = await _helloThenSilence(proxy.port);
        if (c != null) attackers.add(c);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Direct (not via the proxy) attempts from the same IP: all 4 slots are held by the
      // attackers, so every one must be refused.
      final early = await _openAndCount(port, 3);
      await Future<void>.delayed(
        const Duration(seconds: 3),
      ); // well past the 1 s timeout
      final late = await _openAndCount(port, 3);
      // ignore: avoid_print
      print(
        'R5 attackers connected=${attackers.length}, server-closed upstreams='
        '${proxy.upstreamClosedByServer}, direct attempts still open at 0.3 s: $early, at 3.3 s: $late',
      );
      for (final a in attackers) {
        a.destroy();
      }
      expect(attackers.length, 4);
      expect(early, 0, reason: 'phase-2 sockets hold their slots at 0.3 s');
      expect(
        late,
        0,
        reason: 'phase-2 sockets must stay counted after the timeout: the cap holds',
      );
    });

    test('R7 stop(force: true) with phase-1 AND phase-2 stalled sockets returns quickly and the port can be reused', () async {
      final server = _tlsServer(
        total: 16,
        perIp: 6,
        hsTimeout: const Duration(seconds: 30),
      );
      final port = await server.start();
      final proxy = await _Proxy.start(port, stallAfterRecord: true);
      addTearDown(proxy.close);
      final phase1 = await _Raw.open(port);
      phase1.socket.add(_recordHeader512);
      await phase1.socket.flush();
      final phase2 = <Socket>[];
      for (var i = 0; i < 2; i++) {
        final c = await _helloThenSilence(proxy.port);
        if (c != null) phase2.add(c);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final sw = Stopwatch()..start();
      await server.stop(force: true).timeout(const Duration(seconds: 5));
      final took = sw.elapsedMilliseconds;
      final p1 = await phase1.closesWithin(const Duration(seconds: 2));
      // ignore: avoid_print
      print('R7 stop(force) took $took ms; phase-1 client closed after: $p1');
      expect(
        p1,
        isNotNull,
        reason: 'a phase-1 socket must be closed by stop(force)',
      );
      final again = _tlsServer(port: port);
      expect(await again.start(), port);
      await again.stop(force: true);
      for (final s in phase2) {
        s.destroy();
      }
    });
  });
}
