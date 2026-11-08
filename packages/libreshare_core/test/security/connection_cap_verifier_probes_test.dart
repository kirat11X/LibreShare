// VERIFIER probes for E5 / R4a (written by the verifier, a different agent from the tester and the
// coder). They exercise what the wrapper must not break: remote-address keyed state (PinGuard,
// rate limiter), slot accounting under abandoned TLS handshakes and connection churn, a big chunk
// PUT beside idle sockets, repeated stop()/start() on one port, and the peer certificate.
//
// Labels: P1 PinGuard key, P2 rate limiter, P3 abandoned handshakes, P4 churn, P5 big chunk,
// P6 stop/start, X1 remote address seen by handler (plain + TLS), X2 peer certificate forwarded,
// X3 half-closing client must not escape the per-IP cap. (Round 3: the print-only X4/X5
// characterisations were removed; X4/X5/X5b/X6/X7/X8 live in connection_cap_verifier_round2_test.dart.)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/server/capped_server_socket.dart';
import 'package:test/test.dart';

import '../helpers/api_fake_handler.dart';
import '../helpers/p3_secure_handler.dart';
import '../helpers/p3_secure_rig.dart';
import '../helpers/p3v_support.dart';

const _pin = '482913';

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

/// Waits until [perIp] sockets from 127.0.0.1 all stay open and the next one is closed (no slot
/// of this source leaked). Returns the seconds it took, or null when [within] ran out.
Future<double?> _slotsFree(
  int port,
  int perIp, {
  Duration within = const Duration(seconds: 5),
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < within) {
    final open = await _openAndCount(
      port,
      perIp + 1,
      wait: const Duration(milliseconds: 300),
    );
    if (open == perIp) return sw.elapsedMilliseconds / 1000;
  }
  return null;
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

Future<int> _httpStatus(int port, String path) async {
  final c = HttpClient();
  try {
    final req = await c.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
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
}) => ApiServer(
  handler: handler ?? P3SecureHandler(),
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

ApiServer _plainServer({
  int total = 64,
  int perIp = 16,
  int port = 0,
  IncomingTransferHandler? handler,
}) => ApiServer(
  handler: handler ?? FakeIncomingHandler(),
  bindAddress: InternetAddress.loopbackIPv4,
  preferredPort: port,
  maxPortFallback: port,
  enableRateLimit: false,
  maxConnections: total,
  maxConnectionsPerIp: perIp,
);

void main() {
  group('P1 PinGuard keyed by the real source address (TLS profile)', () {
    late PinGuard guard;
    late P3Rig rig;
    setUp(() async {
      guard = PinGuard(
        policy: const PinPolicy(mode: PinMode.fixed),
        pin: _pin,
      );
      rig = await P3Rig.start(handler: P3vPinHandler(guard));
    });
    tearDown(() => rig.stop());

    Future<P3Res> send(String pin, {String? from}) => rig.request(
      'POST',
      '/sessions',
      body: p3vSessionBodyWithPin(p3Alice, pin),
      headers: {'content-type': 'application/json'},
      signAs: p3Alice,
      from: from,
    );

    test('P1 five wrong PINs from 127.0.0.2 block 127.0.0.2 only', () async {
      final wrong = p3vWrongPin(_pin);
      for (var i = 1; i <= 5; i++) {
        final r = await send(wrong, from: '127.0.0.2');
        expect(r.status, 401, reason: 'strike #$i');
        expect(r.error['code'], 'PIN_INVALID');
      }
      final blocked = await send(_pin, from: '127.0.0.2');
      expect(blocked.status, 403, reason: 'the 5th strike blocks 127.0.0.2');
      expect(blocked.error['code'], 'BLOCKED');
      // Not a shared key: other sources are unaffected by 127.0.0.2's strikes.
      expect((await send(_pin, from: '127.0.0.3')).status, 202);
      expect((await send(_pin)).status, 202);
    });

    test(
      'P1b strikes of two sources are counted separately (4 + 4 do not block)',
      () async {
        final wrong = p3vWrongPin(_pin);
        for (var i = 0; i < 4; i++) {
          expect((await send(wrong, from: '127.0.0.2')).status, 401);
          expect((await send(wrong, from: '127.0.0.3')).status, 401);
        }
        // If the key were shared, 8 strikes would have blocked everybody.
        expect((await send(_pin, from: '127.0.0.2')).status, 202);
      },
    );
  });

  group('P2 rate limiter separates source addresses', () {
    for (final secure in [true, false]) {
      test(
        'P2 ${secure ? 'TLS' : 'plain'}: 10 requests/min per IP, 127.0.0.2 limited, 127.0.0.3 and 127.0.0.1 not',
        () async {
          final rig = await P3Rig.start(secure: secure, enableRateLimit: true);
          addTearDown(rig.stop);
          final statuses = <int>[];
          Future<P3Res> post(String? from) => secure
              ? rig.postSession(p3Alice, from: from)
              : rig.request(
                  'POST',
                  '/sessions',
                  body: p3SessionBody(p3Alice),
                  headers: {'content-type': 'application/json'},
                  from: from,
                );
          for (var i = 0; i < 12; i++) {
            statuses.add((await post('127.0.0.2')).status);
          }
          expect(
            statuses.where((s) => s == 429).length,
            2,
            reason: '$statuses',
          );
          expect(statuses.take(10).every((s) => s != 429), isTrue);
          expect((await post('127.0.0.3')).status, isNot(429));
          expect((await post(null)).status, isNot(429));
        },
      );
    }
  });

  group('X1 the handler sees the true source address', () {
    test('X1 TLS: onCreateAuthenticated gets 127.0.0.4', () async {
      String? seen;
      final h = P3SecureHandler()
        ..onCreateAuthenticated = (r, remote, peer) async {
          seen = remote;
          return const SessionStatus(
            sessionId: 's',
            status: TransferStatus.pending,
          );
        };
      final rig = await P3Rig.start(handler: h);
      addTearDown(rig.stop);
      await rig.postSession(p3Alice, from: '127.0.0.4');
      expect(seen, '127.0.0.4');
    });

    test('X1b plain: createSession gets 127.0.0.5', () async {
      final h = FakeIncomingHandler();
      String? seen;
      h.onCreateSession = (r, remote) async {
        seen = remote;
        return const SessionStatus(
          sessionId: 's',
          status: TransferStatus.pending,
        );
      };
      final s = _plainServer(handler: h);
      final port = await s.start();
      addTearDown(() => s.stop(force: true));
      final c = HttpClient()
        ..connectionFactory = (uri, ph, pp) => Socket.startConnect(
          uri.host,
          uri.port,
          sourceAddress: InternetAddress('127.0.0.5'),
        );
      addTearDown(() => c.close(force: true));
      final req = await c.postUrl(
        Uri.parse('http://127.0.0.1:$port$kApiPrefix/sessions'),
      );
      final body = utf8.encode(jsonEncode(sampleRequest().toJson()));
      req.headers.contentType = ContentType.json;
      req.contentLength = body.length;
      req.add(body);
      await (await req.close()).drain<void>();
      expect(seen, '127.0.0.5');
    });
  });

  group('P3 abandoned TLS handshakes free their slots', () {
    test('P3 100 abandoned handshakes (5 shapes): all 16 per-IP slots usable within 5 s', () async {
      final server = _tlsServer();
      final port = await server.start();
      addTearDown(() => server.stop(force: true));
      final rnd = Random(7);
      for (var batch = 0; batch < 10; batch++) {
        final futures = <Future<void>>[];
        for (var j = 0; j < 10; j++) {
          final shape = (batch * 10 + j) % 5;
          futures.add(() async {
            final s = await Socket.connect('127.0.0.1', port);
            switch (shape) {
              case 0:
                s.destroy();
              case 1:
                // TLS record header claiming 512 bytes, then nothing
                s.add([0x16, 0x03, 0x01, 0x02, 0x00]);
                await s.flush();
                s.destroy();
              case 2:
                // a real ClientHello, abandoned at a random moment
                unawaited(
                  SecureSocket.secure(
                    s,
                    host: '127.0.0.1',
                    context: buildClientContext(),
                    onBadCertificate: (_) => true,
                  ).then<void>((x) => x.destroy(), onError: (Object _) {}),
                );
                await Future<void>.delayed(
                  Duration(milliseconds: rnd.nextInt(4)),
                );
                s.destroy();
              case 3:
                // plaintext HTTP on the TLS port
                s.write('GET /api/v1/info HTTP/1.1\r\nHost: x\r\n\r\n');
                await s.flush();
                await Future<void>.delayed(const Duration(milliseconds: 20));
                s.destroy();
              default:
                // two bytes of a record header, then a graceful FIN
                s.add([0x16, 0x03]);
                await s.flush();
                await s.close();
                s.destroy();
            }
          }());
        }
        await Future.wait(futures);
      }
      final t = await _slotsFree(port, 16);
      expect(t, isNotNull, reason: 'slots did not come back within 5 s');
      // ignore: avoid_print
      print('P3 slots free after ${t!.toStringAsFixed(2)} s');
      expect(await _httpsStatus(port, '$kApiPrefix/info'), 200);
    });

    test(
      'P3b global slots: abandoned handshakes from many source addresses',
      () async {
        final server = _tlsServer(total: 20, perIp: 20);
        final port = await server.start();
        addTearDown(() => server.stop(force: true));
        for (var i = 0; i < 100; i++) {
          final from = '127.0.0.${10 + i % 40}';
          final s = await Socket.connect(
            InternetAddress.loopbackIPv4,
            port,
            sourceAddress: InternetAddress(from),
          );
          s.add([0x16, 0x03, 0x01, 0x02, 0x00]);
          await s.flush();
          s.destroy();
        }
        final t = await _slotsFree(port, 20);
        expect(t, isNotNull, reason: 'global slots leaked');
      },
    );
  });

  group('P4 connect/close churn returns every counter to zero', () {
    test('P4 plain: 100 cycles (client close, full request then close, malformed request)', () async {
      final server = _plainServer();
      final port = await server.start();
      addTearDown(() => server.stop(force: true));
      for (var i = 0; i < 100; i++) {
        final s = await Socket.connect('127.0.0.1', port);
        s.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
        switch (i % 4) {
          case 0:
            break;
          case 1:
            s.write('GET /api/v1/info HTTP/1.1\r\nHost: x\r\n\r\n');
            await s.flush();
            await Future<void>.delayed(const Duration(milliseconds: 5));
          case 2:
            s.write('NOT HTTP AT ALL\r\n\r\n');
            await s.flush();
            await Future<void>.delayed(const Duration(milliseconds: 5));
          default:
            s.write('GET /api/v1/info HTTP/1.1\r\nHost: x\r\nX-Slow: a\r\n');
            await s.flush();
        }
        s.destroy();
      }
      final t = await _slotsFree(port, 16);
      expect(t, isNotNull, reason: 'a slot leaked');
      expect(await _httpStatus(port, '$kApiPrefix/info'), 200);
    });

    test('P4b TLS: 100 full handshakes then close', () async {
      final server = _tlsServer();
      final port = await server.start();
      addTearDown(() => server.stop(force: true));
      for (var i = 0; i < 100; i++) {
        final s = await SecureSocket.connect(
          '127.0.0.1',
          port,
          context: buildClientContext(),
          onBadCertificate: (_) => true,
        );
        s.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
        if (i % 2 == 0) {
          s.write('GET /api/v1/info HTTP/1.1\r\nHost: x\r\n\r\n');
          await s.flush();
          await Future<void>.delayed(const Duration(milliseconds: 3));
        }
        s.destroy();
      }
      final t = await _slotsFree(port, 16);
      expect(t, isNotNull, reason: 'a TLS slot leaked');
      expect(await _httpsStatus(port, '$kApiPrefix/info'), 200);
    });

    test('P4c server-side close (Connection: close) frees the slot', () async {
      final server = _plainServer(total: 4, perIp: 2);
      final port = await server.start();
      addTearDown(() => server.stop(force: true));
      for (var i = 0; i < 30; i++) {
        final s = await Socket.connect('127.0.0.1', port);
        final done = Completer<void>();
        s.listen(
          (_) {},
          onDone: done.complete,
          onError: (Object _) => done.complete(),
        );
        s.write(
          'GET /api/v1/info HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
        );
        await done.future.timeout(const Duration(seconds: 3));
        s.destroy();
      }
      expect(await _slotsFree(port, 2), isNotNull);
    });
  });

  test('P5 4 MiB chunk PUT over TLS completes while 15 other sockets of the same IP are idle', () async {
    final rig = await P3Rig.start();
    addTearDown(rig.stop);
    // the rig uses the default limits (64 / 16)
    final idle = <Socket>[];
    for (var i = 0; i < 15; i++) {
      idle.add(await Socket.connect('127.0.0.1', rig.port));
    }
    addTearDown(() {
      for (final s in idle) {
        s.destroy();
      }
    });
    final body = Uint8List(4 * 1024 * 1024);
    for (var i = 0; i < body.length; i++) {
      body[i] = i & 0xff;
    }
    final sw = Stopwatch()..start();
    final r = await rig.request(
      'PUT',
      '/sessions/s1/files/f1/chunks/0',
      body: body,
      headers: {'authorization': 'Bearer tok', kChunkHashHeader: 'b' * 64},
      timeout: const Duration(seconds: 30),
    );
    expect(r.status, 200, reason: r.text);
    expect(rig.handler.last('putChunk').byteCount, body.length);
    // ignore: avoid_print
    print('P5 4 MiB over TLS: ${sw.elapsedMilliseconds} ms');
  });

  group('P6 stop() then start() on the same port', () {
    for (final tls in [false, true]) {
      for (final force in [true, false]) {
        test(
          'P6 ${tls ? 'TLS' : 'plain'} stop(force: $force) x20, same port',
          () async {
            var s = tls ? _tlsServer() : _plainServer();
            final port = await s.start();
            await s.stop(force: true);
            for (var i = 0; i < 20; i++) {
              s = tls ? _tlsServer(port: port) : _plainServer(port: port);
              expect(await s.start(), port, reason: 'iteration $i');
              // leave an open keep-alive client connection and two idle raw sockets behind
              final raw = [
                await Socket.connect('127.0.0.1', port),
                await Socket.connect('127.0.0.1', port),
              ];
              for (final r in raw) {
                r.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
              }
              final status = tls
                  ? await _httpsStatus(port, '$kApiPrefix/info')
                  : await _httpStatus(port, '$kApiPrefix/info');
              expect(status, 200, reason: 'iteration $i');
              await s.stop(force: force).timeout(const Duration(seconds: 10));
              for (final r in raw) {
                r.destroy();
              }
            }
          },
        );
      }
    }
  });

  test('X2 client certificate: CappedServerSocket vs plain SecureServerSocket (same context, same client)', () async {
    SecurityContext serverCtx() => buildServerContext(p3ServerKey)
      ..setTrustedCertificatesBytes(utf8.encode(p3Alice.key.identity.certPem));
    Future<String> attempt(
      Future<Stream<Socket>> Function() bind,
      int Function() portOf,
    ) async {
      final stream = await bind();
      final got = Completer<Socket>();
      final sub = stream.listen(got.complete, onError: (Object e) {});
      final cctx = buildClientContext()
        ..useCertificateChainBytes(utf8.encode(p3Alice.key.identity.certPem))
        ..usePrivateKeyBytes(p3Alice.key.privateKeyPem());
      SecureSocket? client;
      String clientSide;
      try {
        client = await SecureSocket.connect(
          '127.0.0.1',
          portOf(),
          context: cctx,
          onBadCertificate: (_) => true,
        ).timeout(const Duration(seconds: 3));
        clientSide = 'client connected';
      } on Object catch (e) {
        clientSide = 'client ${e.runtimeType}';
      }
      String serverSide;
      try {
        final accepted = await got.future.timeout(const Duration(seconds: 2));
        final cert = accepted is SecureSocket ? accepted.peerCertificate : null;
        serverSide =
            'accepted ${accepted is SecureSocket ? 'SecureSocket' : accepted.runtimeType} cert=${cert == null
                ? 'null'
                : fingerprintHex(cert.der) == p3Alice.fp
                ? 'alice'
                : 'other'}';
      } on TimeoutException {
        serverSide = 'nothing accepted';
      }
      client?.destroy();
      await sub.cancel();
      return '$clientSide / $serverSide';
    }

    late CappedServerSocket capped;
    final a = await attempt(() async {
      capped = await CappedServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        maxConnections: 4,
        maxConnectionsPerIp: 4,
        securityContext: serverCtx(),
        requestClientCertificate: true,
      );
      return capped;
    }, () => capped.port);
    await capped.close();
    late SecureServerSocket base;
    final b = await attempt(() async {
      base = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        serverCtx(),
        requestClientCertificate: true,
      );
      return base;
    }, () => base.port);
    await base.close();
    // ignore: avoid_print
    print('X2 capped: $a');
    // ignore: avoid_print
    print('X2 baseline SecureServerSocket: $b');
    expect(a, b, reason: 'wrapper must behave like SecureServerSocket');
  });

  test('X3 half-closing clients (FIN after the request) must not escape the per-IP cap 2', () async {
    final h = FakeIncomingHandler();
    final gate = Completer<void>();
    var inHandler = 0;
    h.onGetSession = (id, wait) async {
      inHandler++;
      await gate.future;
      return SessionStatus(sessionId: id, status: TransferStatus.pending);
    };
    final s = _plainServer(total: 64, perIp: 2, handler: h);
    final port = await s.start();
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await s.stop(force: true);
    });
    final socks = <Socket>[];
    for (var i = 0; i < 10; i++) {
      try {
        final c = await Socket.connect('127.0.0.1', port);
        c.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
        c.write(
          'GET $kApiPrefix/sessions/x?wait=20 HTTP/1.1\r\nHost: x\r\n\r\n',
        );
        await c.flush();
        await c.close(); // FIN: write side done, read side stays
        socks.add(c);
      } on Object {
        // refused
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // ignore: avoid_print
    print(
      'X3 per-IP cap 2, 10 half-closed long-poll requests sent: $inHandler reached the handler at once',
    );
    // The cap must hold even when the clients half-close: at most perIp (2) requests in flight.
    expect(
      inHandler,
      lessThanOrEqualTo(2),
      reason: 'half-closed (FIN) sockets were released from the per-IP count while still served',
    );
    for (final c in socks) {
      c.destroy();
    }
  });
}
