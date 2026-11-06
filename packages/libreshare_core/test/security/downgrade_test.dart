// P5 - no downgrade: a secure client never speaks plain HTTP, never follows a redirect to HTTP and
// refuses TLS older than 1.3 (LSP-1 0.3 "never negotiates down", 4.7 compatibility table,
// docs/plans/inc3.md D8, D10, docs/plans/inc3-seams.md data-flow 6).
//
// Peers count what they receive: a plain TCP listener (an LSP/1.0 or plaintext-profile peer), a
// port that speaks both TLS and HTTP (to see a retry over HTTP on the same port) and, where
// `openssl` is installed, a TLS 1.2-only server. Each "must not happen" test has a positive twin.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p5_raw_peer.dart';
import '../helpers/p5_support.dart';

bool _hasOpenssl() {
  try {
    return Process.runSync('openssl', ['version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

final Object _skipNoOpenssl = _hasOpenssl()
    ? false
    : 'openssl is not installed';

const _sentinel = 'DOWNGRADE-SENTINEL-FILE-NAME.bin';

void main() {
  late KeyIdentity me;
  late KeyIdentity other;
  late SecurityConfig sec;
  late DeviceInfo self;
  final peers = <RawPeer>[];
  final clients = <ApiClient>[];

  setUpAll(() {
    me = newIdentity('p5-dg-me');
    other = newIdentity('p5-dg-other');
    sec = secureConfig(me);
    self = infoFor('p5-dg-me', me.identity.fingerprint);
  });

  tearDown(() async {
    for (final c in clients) {
      c.close();
    }
    clients.clear();
    for (final p in peers) {
      await p.close();
    }
    peers.clear();
  });

  ApiClient secure(int port, {String? pin}) {
    final c = secureClient(port, sec, pin: pin);
    clients.add(c);
    return c;
  }

  ApiClient plaintext(int port) {
    final c = ApiClient(host: '127.0.0.1', port: port);
    clients.add(c);
    return c;
  }

  Future<Object?> outcome(Future<Object?> f) async {
    try {
      return await f;
    } on Object catch (e) {
      return e;
    }
  }

  void expectNoPlaintext(RawPeer peer, {String reason = ''}) {
    expect(peer.requests, isEmpty, reason: reason);
    final seen = peer.receivedText;
    expect(seen, isNot(contains('HTTP/1')), reason: reason);
    expect(seen, isNot(contains(_sentinel)), reason: reason);
    expect(seen.toLowerCase(), isNot(contains('x-ls-auth')), reason: reason);
    expect(seen, isNot(contains('POST ')), reason: reason);
    expect(seen, isNot(contains('GET ')), reason: reason);
  }

  // LSP-1 4.7: "secure -> LSP/1.0 or plaintext receiver: refused locally ... a secure client
  // never opens a plain-HTTP connection by itself", 0 bytes of HTTP without the override.
  group('plaintext peer', () {
    final ops = <String, Future<Object?> Function(ApiClient c)>{
      'info': (c) => c.info(),
      'createSession': (c) => c.createSession(
        sampleRequest(infoFor('p5-dg-me', 'AB' * 32), sentinel: _sentinel),
      ),
      'revealSas': (c) => c.revealSas('sess-1', nonce: 'A' * 22),
      'putChunk': (c) => c.putChunk(
        'sess-1',
        'f1',
        0,
        Stream.value(_sentinel.codeUnits),
        length: _sentinel.length,
        chunkSha256: '00' * 32,
        token: 'tok',
      ),
    };
    for (final pinned in [false, true]) {
      for (final op in ops.entries) {
        test(
          'plaintext_peer_refused_when_tls_required_zero_bytes_sent: ${op.key}, ${pinned ? 'pinned' : 'first contact'}',
          () async {
            final peer = await RawPlainPeer.start();
            peers.add(peer);
            final c = secure(
              peer.port,
              pin: pinned ? other.identity.fingerprint : null,
            );
            final err = await outcome(op.value(c));
            expect(err, isA<InsecurePeerException>());
            await settle();
            expectNoPlaintext(peer);
          },
        );
      }
    }

    test('control: the plaintext profile DOES reach the same peer (the harness sees HTTP)', () async {
      final peer = await RawPlainPeer.start();
      peers.add(peer);
      final info = await plaintext(peer.port).info();
      expect(info.fingerprint, isEmpty);
      await plaintext(peer.port)
          .createSession(sampleRequest(self, sentinel: _sentinel));
      expect(peer.requests.map((r) => '$r'), [
        'GET /api/v1/info',
        'POST /api/v1/sessions',
      ]);
      expect(peer.receivedText, contains(_sentinel));
      expect(
        peer.requests.last.header(kAuthHeader),
        isNull,
        reason: 'the plaintext profile is byte-identical to Inc 1/2: no proof header',
      );
    });

    test('InsecurePeerException carries fixed text only', () async {
      final peer = await RawPlainPeer.start();
      peers.add(peer);
      final err = await outcome(secure(peer.port).info());
      expect(err, isA<InsecurePeerException>());
      final text = '$err';
      expect(text, isNot(contains('127.0.0.1')));
      expect(text, isNot(matches(fullHex)));
    });
  });

  // A listener that accepts the connection and drops it (no HTTP, no TLS) is a failure, but not a
  // key change and not a reason to retry in the clear.
  group('no retry in the clear after a TLS failure', () {
    test('peer that closes silently: some exception, never a pin mismatch, zero plaintext', () async {
      final peer = await RawPlainPeer.start(garbageReply: GarbageReply.silent);
      peers.add(peer);
      final err = await outcome(
        secure(peer.port)
            .createSession(sampleRequest(self, sentinel: _sentinel)),
      );
      expect(err, isA<Exception>());
      expect(err, isNot(isA<PeerFingerprintMismatchException>()));
      await settle();
      expectNoPlaintext(peer);
    });

    test(
      'client_never_retries_over_http_after_tls_failure (pin mismatch)',
      () async {
        final peer = await RawSniffPeer.start(other);
        peers.add(peer);
        final c = secure(peer.port, pin: me.identity.fingerprint); // wrong pin
        final err = await outcome(
          c.createSession(sampleRequest(self, sentinel: _sentinel)),
        );
        expect(err, isA<PeerFingerprintMismatchException>());
        await settle();
        expect(peer.tlsHandshakesStarted, greaterThanOrEqualTo(1));
        expect(
          peer.plainConnections,
          0,
          reason: 'no connection without TLS was opened',
        );
        expect(peer.plainRequests, isEmpty);
        expect(peer.receivedText, isNot(contains(_sentinel)));
      },
    );

    test(
      'repeated attempts after a pin mismatch never go plain either',
      () async {
        final peer = await RawSniffPeer.start(other);
        peers.add(peer);
        final c = secure(peer.port, pin: fingerprintHex([1, 2, 3]));
        await outcome(c.info());
        await outcome(c.info());
        await settle();
        expect(peer.plainConnections, 0);
      },
    );

    test(
      'control: a plaintext-profile client IS seen as plain by the same peer',
      () async {
        final peer = await RawSniffPeer.start(other);
        peers.add(peer);
        await outcome(plaintext(peer.port).info());
        expect(peer.plainConnections, 1);
        expect(peer.plainRequests.map((r) => '$r'), ['GET /api/v1/info']);
      },
    );

    test(
      'control: a secure client reaches the sniffing peer over TLS only',
      () async {
        final peer = await RawSniffPeer.start(other);
        peers.add(peer);
        final info = await secure(
          peer.port,
          pin: other.identity.fingerprint,
        ).info();
        expect(info.deviceId, 'p5-dg-other');
        expect(peer.plainConnections, 0);
        expect(peer.requests, hasLength(1));
      },
    );
  });

  // LSP-1 0.3: "TLS 1.3, ... redirects are never followed".
  group('redirects', () {
    test('a redirect to http:// is not followed', () async {
      final plain = await RawPlainPeer.start();
      peers.add(plain);
      final tlsPeer = await RawTlsPeer.start(
        other,
        handler: (r) => RawResponse(
          307,
          headers: {'location': 'http://127.0.0.1:${plain.port}/api/v1/info'},
        ),
      );
      peers.add(tlsPeer);
      final err = await outcome(
        secure(tlsPeer.port, pin: other.identity.fingerprint).info(),
      );
      expect(err, isNot(isA<DeviceInfo>()));
      expect(err, isA<Exception>());
      await settle();
      expect(tlsPeer.requests, hasLength(1), reason: 'the redirect was served');
      expect(plain.requests, isEmpty);
      expect(plain.bytesReceived, 0);
    });

    test(
      'a redirect to https:// on another port is not followed either',
      () async {
        final target = await RawTlsPeer.start(other);
        peers.add(target);
        final tlsPeer = await RawTlsPeer.start(
          other,
          handler: (r) => RawResponse(
            307,
            headers: {
              'location': 'https://127.0.0.1:${target.port}/api/v1/info',
            },
          ),
        );
        peers.add(tlsPeer);
        await outcome(
          secure(tlsPeer.port, pin: other.identity.fingerprint).info(),
        );
        await settle();
        expect(target.requests, isEmpty);
      },
    );

    test('control: without the redirect the target is reachable', () async {
      final plain = await RawPlainPeer.start();
      peers.add(plain);
      await plaintext(plain.port).info();
      expect(plain.requests, hasLength(1));
    });
  });

  // LSP-1 0.3 / plan D8: "TLS >= 1.3 ... test with openssl s_client -tls1_2 when present".
  group('TLS 1.2-only server (openssl)', () {
    late Directory tmp;
    Process? proc;

    setUp(() => tmp = Directory.systemTemp.createTempSync('p5_tls12'));
    tearDown(() async {
      proc?.kill();
      if (proc != null) await proc!.exitCode;
      proc = null;
      tmp.deleteSync(recursive: true);
    });

    Future<int> startOpenssl(IdentityProvider id, String versionFlag) async {
      File('${tmp.path}/cert.pem').writeAsStringSync(id.identity.certPem);
      File('${tmp.path}/key.pem').writeAsBytesSync(id.privateKeyPem());
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      final ready = Completer<void>();
      proc = await Process.start('openssl', [
        's_server',
        '-accept',
        '$port',
        '-cert',
        '${tmp.path}/cert.pem',
        '-key',
        '${tmp.path}/key.pem',
        '-www',
        versionFlag,
      ]);
      proc!.stdout.transform(utf8.decoder).listen((chunk) {
        if (chunk.contains('ACCEPT') && !ready.isCompleted) ready.complete();
      });
      unawaited(proc!.stderr.drain<void>());
      await ready.future.timeout(const Duration(seconds: 10));
      return port;
    }

    test('tls12_only_client_refused: handshake fails, nothing is sent over TLS 1.2', () async {
      final port = await startOpenssl(other, '-tls1_2');
      final c = ApiClient(
        host: '127.0.0.1',
        port: port,
        security: sec,
        expectedFingerprint: other.identity.fingerprint,
        requestTimeout: const Duration(seconds: 3),
      );
      clients.add(c);
      final err = await outcome(c.info());
      expect(err, isA<Exception>());
      expect(
        err,
        isNot(isA<LsException>()),
        reason: 'no HTTP answer was ever read',
      );
      expect(
        err,
        isNot(isA<TimeoutException>()),
        reason: 'the handshake failed, not the request',
      );
      expect(err, isNot(isA<PeerFingerprintMismatchException>()));
      expect(
        c.serverFingerprint,
        anyOf(isNull, equals(other.identity.fingerprint)),
      );
    }, skip: _skipNoOpenssl);

    test('control: the same server at TLS 1.3 completes the handshake and gets the request', () async {
      final port = await startOpenssl(other, '-tls1_3');
      final c = ApiClient(
        host: '127.0.0.1',
        port: port,
        security: sec,
        expectedFingerprint: other.identity.fingerprint,
        requestTimeout: const Duration(seconds: 2),
      );
      clients.add(c);
      final err = await outcome(c.info());
      // `s_server -www` answers an HTML page that never ends: an HTTP-level outcome, not TLS.
      expect(err, anyOf(isA<LsException>(), isA<TimeoutException>()));
      expect(c.serverFingerprint, other.identity.fingerprint);
    }, skip: _skipNoOpenssl);
  });
}
