// Real TLS over loopback with identities from generateIdentity (docs/plans/inc3.md D1, D2, D8).
// openssl is used as an independent oracle where installed; those tests skip without it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/src/security/cert_factory.dart';
import 'package:libreshare_core/src/security/crypto_primitives.dart';
import 'package:libreshare_core/src/security/key_identity.dart';
import 'package:libreshare_core/src/security/tls_context.dart';
import 'package:test/test.dart';

bool _hasOpenssl() {
  try {
    return Process.runSync('openssl', ['version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

final bool hasOpenssl = _hasOpenssl();
final Object skipNoOpenssl = hasOpenssl ? false : 'openssl missing';

/// Minimal [X509Certificate] carrying only the DER bytes.
class _FakeCert implements X509Certificate {
  _FakeCert(this.der);
  @override
  final Uint8List der;
  @override
  String get pem => throw UnimplementedError();
  @override
  Uint8List get sha1 => throw UnimplementedError();
  @override
  String get subject => 'CN=fake';
  @override
  String get issuer => 'CN=fake';
  @override
  DateTime get startValidity => DateTime.utc(2020);
  @override
  DateTime get endValidity => DateTime.utc(2030);
}

class _Server {
  _Server(this.http, this.requests, this.clientCerts);
  final HttpServer http;
  final List<String> requests;
  final List<X509Certificate?> clientCerts;
  int get port => http.port;
  Future<void> close() => http.close(force: true);
}

Future<_Server> _startServer(SecurityContext ctx) async {
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    ctx,
  );
  final requests = <String>[];
  final clientCerts = <X509Certificate?>[];
  server.listen((req) {
    requests.add('${req.method} ${req.uri.path}');
    clientCerts.add(req.certificate);
    req.response
      ..statusCode = 200
      ..write('pong');
    unawaited(req.response.close());
  }, onError: (Object _) {});
  return _Server(server, requests, clientCerts);
}

/// Client that accepts a certificate only if its fingerprint equals [pin]; records what the
/// pin callback saw.
class _PinClient {
  _PinClient(this.pin, {SecurityContext? context}) {
    http = HttpClient(context: context ?? buildClientContext())
      ..badCertificateCallback = (cert, host, port) {
        callbackCalls++;
        lastDer = cert.der;
        lastHost = host;
        return certificateMatchesPin(cert, pin);
      };
  }
  final String pin;
  late final HttpClient http;
  int callbackCalls = 0;
  Uint8List? lastDer;
  String? lastHost;

  /// [readBody] false is for `openssl s_server -www`, whose HTTP/1.0 body never terminates.
  Future<({int status, String body})> get(
    int port, {
    bool readBody = true,
  }) async {
    final req = await http.getUrl(Uri.parse('https://127.0.0.1:$port/ping'));
    final res = await req.close();
    return (
      status: res.statusCode,
      body: readBody ? await utf8.decodeStream(res) : '',
    );
  }
}

void main() {
  late KeyIdentity serverId;
  late KeyIdentity otherId;

  setUpAll(() {
    serverId = KeyIdentity.fromGenerated(
      generateIdentity(deviceId: 'tls-server'),
    );
    otherId = KeyIdentity.fromGenerated(
      generateIdentity(deviceId: 'tls-other'),
    );
  });

  group('certificateMatchesPin', () {
    final der = Uint8List.fromList(List.generate(300, (i) => i & 0xFF));
    final fp = fingerprintHex(der);

    test('matches the SHA-256 of the DER, case-insensitively on the expected value', () {
      expect(certificateMatchesPin(_FakeCert(der), fp), isTrue);
      expect(certificateMatchesPin(_FakeCert(der), fp.toLowerCase()), isTrue);
    });

    test(
      'a different certificate or a one-character-off pin does not match',
      () {
        final other = Uint8List.fromList(der)..[0] ^= 1;
        expect(certificateMatchesPin(_FakeCert(other), fp), isFalse);
        final off = '${fp.substring(0, 63)}${fp[63] == 'A' ? 'B' : 'A'}';
        expect(certificateMatchesPin(_FakeCert(der), off), isFalse);
      },
    );

    test('malformed expected values never match (and never throw)', () {
      for (final bad in [
        '',
        'abc',
        fp.substring(1),
        '${fp}00',
        ' $fp',
        '$fp\n',
        'g' * 64,
      ]) {
        expect(
          certificateMatchesPin(_FakeCert(der), bad),
          isFalse,
          reason: bad,
        );
      }
    });

    test('an empty DER never matches, not even the hash of nothing', () {
      expect(
        certificateMatchesPin(
          _FakeCert(Uint8List(0)),
          'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855',
        ),
        isFalse,
      );
    });
  });

  group('loopback TLS with generated identities', () {
    late _Server server;
    setUp(
      () async => server = await _startServer(buildServerContext(serverId)),
    );
    tearDown(() => server.close());

    test('a client pinning the right fingerprint can GET', () async {
      final client = _PinClient(serverId.identity.fingerprint);
      final r = await client.get(server.port);
      expect(r.status, 200);
      expect(r.body, 'pong');
      expect(server.requests, ['GET /ping']);
      client.http.close(force: true);
    });

    test('the pin callback sees the full DER of the identity certificate (IP host, no SAN)', () async {
      final client = _PinClient(serverId.identity.fingerprint);
      await client.get(server.port);
      expect(client.callbackCalls, greaterThanOrEqualTo(1));
      expect(client.lastDer, serverId.identity.certDer);
      expect(client.lastHost, '127.0.0.1');
      client.http.close(force: true);
    });

    test(
      'a client pinning a different fingerprint is refused before any request',
      () async {
        final client = _PinClient(otherId.identity.fingerprint);
        await expectLater(
          client.get(server.port),
          throwsA(isA<HandshakeException>()),
        );
        expect(client.callbackCalls, greaterThanOrEqualTo(1));
        expect(server.requests, isEmpty);
        client.http.close(force: true);
      },
    );

    test('the lowercase form of the right pin works too', () async {
      final client = _PinClient(serverId.identity.fingerprint.toLowerCase());
      expect((await client.get(server.port)).status, 200);
      client.http.close(force: true);
    });

    test('a client that trusts nothing and has no callback is refused (no system roots)', () async {
      final bare = HttpClient(context: buildClientContext());
      await expectLater(
        bare
            .getUrl(Uri.parse('https://127.0.0.1:${server.port}/ping'))
            .then((r) => r.close()),
        throwsA(isA<HandshakeException>()),
      );
      expect(server.requests, isEmpty);
      bare.close(force: true);
    });

    test('the server never asks for a client certificate', () async {
      final clientCtx = buildClientContext()
        ..useCertificateChainBytes(utf8.encode(otherId.identity.certPem))
        ..usePrivateKeyBytes(otherId.privateKeyPem());
      final client = _PinClient(
        serverId.identity.fingerprint,
        context: clientCtx,
      );
      expect((await client.get(server.port)).status, 200);
      expect(server.clientCerts, [null]);
      client.http.close(force: true);
    });

    test(
      'repeated connections keep working (keep-alive and fresh sockets)',
      () async {
        final client = _PinClient(serverId.identity.fingerprint);
        for (var i = 0; i < 5; i++) {
          expect((await client.get(server.port)).body, 'pong');
        }
        client.http.close(force: true);
        final second = _PinClient(serverId.identity.fingerprint);
        expect((await second.get(server.port)).body, 'pong');
        second.http.close(force: true);
      },
    );
  });

  test(
    'an expired certificate is accepted when pinned (pins ignore expiry)',
    () async {
      final old = KeyIdentity.fromGenerated(
        generateIdentity(
          deviceId: 'tls-expired',
          now: DateTime.utc(2010, 1, 1),
        ),
      );
      expect(
        parseCertificate(old.identity.certDer).notAfter
            .isBefore(DateTime.now()),
        isTrue,
      );
      final server = await _startServer(buildServerContext(old));
      final client = _PinClient(old.identity.fingerprint);
      expect((await client.get(server.port)).status, 200);
      client.http.close(force: true);
      await server.close();
    },
  );

  group('TLS version floor (D8)', () {
    test(
      'openssl s_client -tls1_2 is refused by our listener; -tls1_3 works',
      skip: skipNoOpenssl,
      () async {
        final server = await _startServer(buildServerContext(serverId));
        Future<(int, String)> s(String flag) async {
          final p = await Process.start('openssl', [
            's_client',
            flag,
            '-connect',
            '127.0.0.1:${server.port}',
          ]);
          p.stdin.add(utf8.encode('GET /ping HTTP/1.0\r\n\r\n'));
          await p.stdin.close();
          final out = await utf8.decodeStream(p.stdout);
          await utf8.decodeStream(p.stderr);
          return (await p.exitCode, out);
        }

        final (code12, out12) = await s('-tls1_2');
        expect(code12, isNot(0));
        expect(out12, contains('Cipher is (NONE)'));
        expect(server.requests, isEmpty);
        final (code13, out13) = await s('-tls1_3');
        expect(code13, 0);
        expect(out13, contains('Protocol: TLSv1.3'));
        expect(out13, contains('No client certificate CA names sent'));
        for (var i = 0; i < 40 && server.requests.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(server.requests, ['GET /ping']);
        await server.close();
      },
    );

    test(
      'control: a default-context listener does accept TLS 1.2 (the floor is what refuses)',
      skip: skipNoOpenssl,
      () async {
        final ctx = SecurityContext(withTrustedRoots: false)
          ..useCertificateChainBytes(utf8.encode(serverId.identity.certPem))
          ..usePrivateKeyBytes(serverId.privateKeyPem());
        final server = await _startServer(ctx);
        final p = await Process.start('openssl', [
          's_client',
          '-tls1_2',
          '-connect',
          '127.0.0.1:${server.port}',
        ]);
        p.stdin.add(utf8.encode('GET /ping HTTP/1.0\r\n\r\n'));
        await p.stdin.close();
        final out = await utf8.decodeStream(p.stdout);
        await utf8.decodeStream(p.stderr);
        expect(await p.exitCode, 0);
        expect(out, contains('Protocol: TLSv1.2'));
        await server.close();
      },
    );

    test(
      'our client context refuses a TLS 1.2-only server; accepts the same server at 1.3',
      skip: skipNoOpenssl,
      () async {
        final tmp = Directory.systemTemp.createTempSync('ls_tls12');
        Process? proc;
        try {
          File('${tmp.path}/cert.pem')
              .writeAsStringSync(serverId.identity.certPem);
          File('${tmp.path}/key.pem')
              .writeAsBytesSync(serverId.privateKeyPem());
          Future<int> freePort() async {
            final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
            final port = s.port;
            await s.close();
            return port;
          }

          Future<void> startOpenssl(int port, String versionFlag) async {
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
              if (chunk.contains('ACCEPT') && !ready.isCompleted) {
                ready.complete();
              }
            });
            unawaited(proc!.stderr.drain<void>());
            await ready.future.timeout(const Duration(seconds: 10));
          }

          final p12 = await freePort();
          await startOpenssl(p12, '-tls1_2');
          final c12 = _PinClient(serverId.identity.fingerprint);
          await expectLater(
            c12.get(p12),
            throwsA(isA<HandshakeException>()),
            reason: 'client floor must refuse a TLS 1.2-only server',
          );
          c12.http.close(force: true);
          proc!.kill();
          await proc!.exitCode;

          final p13 = await freePort();
          await startOpenssl(p13, '-tls1_3');
          final c13 = _PinClient(serverId.identity.fingerprint);
          expect((await c13.get(p13, readBody: false)).status, 200);
          c13.http.close(force: true);
        } finally {
          proc?.kill();
          tmp.deleteSync(recursive: true);
        }
      },
    );
  });
}
