// LSP/1.1 conformance of the secure ApiServer, asserted with a raw dart:io client (not ApiClient).
// Spec: LSP-1 0.3 (profiles), 4.3.1 (headers: Date, chunk hash), 4.3.2 (routes), 4.3.4 (secure
// check order, /sas, /pair), 4.3.5 (error envelope), 4.7 (TLS-only listener), 5.1/5.3 delegation.
//
// Check order of POST /sessions as far as the HTTP layer owns it:
//   gate -> rate limit -> body size -> auth -> shape -> version -> consistency
// The handler owns everything after that (sender match, trust, PIN, storage, pending, busy).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/security/crypto_primitives.dart'
    show sha256Hex;
import 'package:test/test.dart';

import '../helpers/api_fake_handler.dart' show FakeIncomingHandler;
import '../helpers/p3_secure_handler.dart';
import '../helpers/p3_secure_rig.dart';

const _json = {'content-type': 'application/json'};

bool _hasOpenssl() {
  try {
    return Process.runSync('openssl', ['version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  late P3Rig rig;
  setUp(() async => rig = await P3Rig.start());
  tearDown(() => rig.stop());

  final alice = p3Alice;

  Map<String, Object?> sessionMap({String v = kProtocolVersionSecure}) {
    final m = SessionRequest(
      sender: alice.info(),
      files: const [
        FileItem(fileId: 'f1', fileName: 'a.bin', size: 10, chunkCount: 1),
      ],
      totalSize: 10,
    ).toJson();
    (m['sender']! as Map)['v'] = v;
    return m;
  }

  Future<P3Res> postSessions(
    Object? json, {
    List<int>? raw,
    bool sign = true,
  }) => rig.request(
    'POST',
    '/sessions',
    json: raw == null ? json : null,
    body: raw,
    headers: _json,
    signAs: sign ? alice : null,
  );

  void expectError(P3Res r, LsErrorCode code) {
    expect(r.status, code.httpStatus, reason: r.text);
    expect(r.header('content-type'), contains('application/json'));
    expect(r.error['code'], code.wire);
    expect(r.error['retryable'], code.retryable);
    expect(r.error['message'], isA<String>());
  }

  // ---------------------------------------------------------------------------------------
  group(
    'construction (seams: security.isSecure needs a SecureTransferHandler)',
    () {
      test(
        'a secure server with a plaintext-only handler is an ArgumentError',
        () async {
          Future<void> build() async {
            final s = ApiServer(
              handler: FakeIncomingHandler(),
              security: SecurityConfig.tls(
                identity: p3ServerKey,
                trust: InMemoryTrustStore(),
              ),
              bindAddress: InternetAddress.loopbackIPv4,
              preferredPort: 0,
            );
            try {
              await s.start();
            } finally {
              await s.stop(force: true);
            }
          }

          await expectLater(build(), throwsArgumentError);
        },
      );

      test('twin: a plaintext server accepts either handler type', () async {
        for (final h in <IncomingTransferHandler>[
          FakeIncomingHandler(),
          P3SecureHandler(),
        ]) {
          final s = ApiServer(
            handler: h,
            bindAddress: InternetAddress.loopbackIPv4,
            preferredPort: 0,
          );
          await s.start();
          await s.stop(force: true);
        }
      });
    },
  );

  // ---------------------------------------------------------------------------------------
  group('transport (0.3, 4.7)', () {
    test('the listener presents the identity certificate: its hash is the server fingerprint', () async {
      final r = await rig.request('GET', '/info');
      expect(r.status, 200, reason: r.text);
      expect(rig.seenServerFingerprints, isNotEmpty);
      expect(rig.seenServerFingerprints.toSet(), {rig.serverFp});
    });

    test('a plaintext HTTP client is answered with a closed connection and no HTTP bytes', () async {
      final raw = await P3Raw.plain(rig.port);
      addTearDown(raw.destroy);
      raw.write('GET $kApiPrefix/info HTTP/1.1\r\nHost: x\r\n\r\n');
      expect(
        await raw.waitClosed(),
        isTrue,
        reason: 'server must close the connection',
      );
      final text = raw.text;
      expect(text, isNot(contains('HTTP/')));
      expect(text, isNot(contains('libreshare')));
      expect(text, isNot(contains('error')));
      expect(rig.handler.calls, isEmpty);
      // the listener survived: a TLS client is still served
      expect((await rig.request('GET', '/info')).status, 200);
    });

    test('twin: the plaintext PROFILE does answer a plain HTTP client (the check can see an answer)', () async {
      final plain = await P3Rig.start(secure: false);
      addTearDown(plain.stop);
      final raw = await P3Raw.plain(plain.port);
      addTearDown(raw.destroy);
      raw.write(
        'GET $kApiPrefix/info HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      expect(await raw.waitClosed(), isTrue);
      expect(raw.text, startsWith('HTTP/1.1 200'));
    });

    test('a TLS client does not get a plaintext-profile answer on the same port (no HTTP downgrade)', () async {
      final raw = await P3Raw.plain(rig.port);
      addTearDown(raw.destroy);
      raw.write(
        'POST $kApiPrefix/sessions HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}',
      );
      await raw.waitClosed();
      expect(rig.handler.calls, isEmpty);
    });

    final hasOpenssl = _hasOpenssl();
    test(
      'a TLS 1.2-only client is refused; TLS 1.3 is served',
      skip: hasOpenssl ? false : 'openssl not installed',
      () async {
        Future<(int, String)> s(String flag) async {
          final p = await Process.start('openssl', [
            's_client',
            flag,
            '-connect',
            '127.0.0.1:${rig.port}',
          ]);
          p.stdin.add(utf8.encode('GET $kApiPrefix/info HTTP/1.0\r\n\r\n'));
          await p.stdin.close();
          final out = await utf8.decodeStream(p.stdout);
          await utf8.decodeStream(p.stderr);
          return (await p.exitCode, out);
        }

        final (code12, out12) = await s('-tls1_2');
        expect(code12, isNot(0));
        expect(out12, contains('Cipher is (NONE)'));
        expect(rig.handler.calls, isEmpty);
        final (code13, out13) = await s('-tls1_3');
        expect(code13, 0);
        expect(out13, contains('Protocol: TLSv1.3'));
        for (var i = 0; i < 40 && rig.handler.names.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(rig.handler.names, [
          'deviceInfo',
        ], reason: 'TLS 1.3 reached GET /info');
      },
    );
  });

  // ---------------------------------------------------------------------------------------
  group('Date header on every secure response (4.3.1, 4.3.6 Clock)', () {
    test('present, parseable and close to now on 2xx, 4xx and 5xx answers of every route', () async {
      final b = p3SessionBody(alice);
      rig.handler.onGetSession = (sid, wait) async =>
          throw StateError('boom'); // 500 on /sessions/boom
      final responses = <String, P3Res>{
        'GET /info 200': await rig.request('GET', '/info'),
        'unknown route 404': await rig.request('GET', '/nope'),
        'wrong method 404': await rig.request('DELETE', '/info'),
        'POST /sessions 202': await rig.postSession(alice, body: b),
        'POST /sessions 401': await postSessions(null, raw: b, sign: false),
        'POST /sessions 400': await postSessions(
          null,
          raw: utf8.encode('{nope'),
        ),
        'POST /sessions 413': await postSessions(
          null,
          raw: p3SessionBody(alice, length: 5 * 1024 * 1024),
        ),
        'GET /sessions 500': await rig.request('GET', '/sessions/boom'),
        'chunk 400 (no hash)': await rig.request(
          'PUT',
          '/sessions/s1/files/f1/chunks/0',
          body: [1],
          headers: {'authorization': 'Bearer t'},
        ),
        'chunk 200': await rig.request(
          'PUT',
          '/sessions/s1/files/f1/chunks/0',
          body: [1],
          headers: {'authorization': 'Bearer t', kChunkHashHeader: 'b' * 64},
        ),
      };
      expect(responses['GET /sessions 500']!.status, 500);
      final now = DateTime.now().toUtc();
      for (final e in responses.entries) {
        final d = e.value.date;
        expect(d, isNotNull, reason: '${e.key}: missing or unparsable Date');
        expect(
          d!.difference(now).abs(),
          lessThan(const Duration(seconds: 10)),
          reason: e.key,
        );
      }
    });

    test(
      'plaintext profile is not required to add one (unchanged Inc 1 headers)',
      () async {
        // Guards "byte-identical": the plaintext response header NAMES stay what Inc 1/2 sent.
        final plain = await P3Rig.start(secure: false);
        addTearDown(plain.stop);
        final r = await plain.request('GET', '/info');
        expect(r.status, 200);
        expect(r.headerNames, isNot(contains('x-powered-by')));
        expect(r.header('cache-control'), 'no-store');
      },
    );

    test(
      'Cache-Control: no-store and no X-Powered-By on secure JSON responses',
      () async {
        for (final r in [
          await rig.request('GET', '/info'),
          await rig.request('GET', '/nope'),
          await postSessions(null, raw: p3SessionBody(alice), sign: false),
        ]) {
          expect(r.header('cache-control'), 'no-store');
          expect(r.headerNames, isNot(contains('x-powered-by')));
        }
      },
    );
  });

  // ---------------------------------------------------------------------------------------
  group('POST /sessions check order (4.3.4 secure order)', () {
    test(
      'auth (401) comes before shape (400): garbage JSON with no proof is 401',
      () async {
        final r = await postSessions(
          null,
          raw: utf8.encode('{nope'),
          sign: false,
        );
        expectError(r, LsErrorCode.authInvalid);
        expect(rig.handler.calls, isEmpty);
      },
    );

    test(
      'shape (400) after auth: garbage JSON with a valid proof is 400',
      () async {
        for (final bad in ['{nope', '[1,2]', '', '{"sender":{}}']) {
          expectError(
            await postSessions(null, raw: utf8.encode(bad)),
            LsErrorCode.badRequest,
          );
        }
        expect(rig.handler.calls, isEmpty);
      },
    );

    test('a sasCommit that is not 43 base64url characters is 400 BAD_REQUEST (shape)', () async {
      final m = sessionMap()..['sasCommit'] = 'too-short';
      expectError(await postSessions(m), LsErrorCode.badRequest);
      expect(rig.handler.calls, isEmpty);
      // twin: 43 characters pass the HTTP layer
      final ok = sessionMap()..['sasCommit'] = 'A' * 43;
      expect((await postSessions(ok)).status, 202);
      expect(
        rig.handler.last('createAuthenticatedSession').request!.sasCommit,
        'A' * 43,
      );
    });

    test('version (426) comes before consistency (400)', () async {
      final m = sessionMap(v: '2.0')..['totalSize'] = 999; // also inconsistent
      final r = await postSessions(m);
      expectError(r, LsErrorCode.upgradeRequired);
      expect(r.map['supported'], ['1']);
      expect(rig.handler.calls, isEmpty);
    });

    test('consistency (400): totalSize must equal the sum of sizes', () async {
      final m = sessionMap()..['totalSize'] = 999;
      expectError(await postSessions(m), LsErrorCode.badRequest);
      expect(rig.handler.calls, isEmpty);
    });

    test('the secure server calls createAuthenticatedSession, never the plaintext createSession', () async {
      expect((await postSessions(sessionMap())).status, 202);
      expect(rig.handler.names, ['createAuthenticatedSession']);
      final c = rig.handler.last('createAuthenticatedSession');
      expect(c.remoteAddress, '127.0.0.1');
      expect(c.request!.files.single.fileId, 'f1');
      expect(c.request!.sender.deviceId, alice.deviceId);
      expect(c.peer!.fingerprint, alice.fp);
    });

    test('handler outcomes pass through: 202 pending, 200 in-progress, LsException statuses', () async {
      rig.handler.onCreateAuthenticated = (_, _, _) async =>
          const SessionStatus(
            sessionId: 's9',
            status: TransferStatus.inProgress,
            acceptedFiles: {'f1': AcceptedFile(token: 'tk')},
          );
      final r = await postSessions(sessionMap());
      expect(r.status, 200);
      expect(r.map['status'], 'IN_PROGRESS');
      rig.handler.onCreateAuthenticated = null;
      for (final code in [
        LsErrorCode.keyChanged,
        LsErrorCode.blocked,
        LsErrorCode.pinRequired,
        LsErrorCode.pinInvalid,
        LsErrorCode.authInvalid,
        LsErrorCode.insufficientStorage,
        LsErrorCode.rateLimited,
        LsErrorCode.busy,
      ]) {
        rig.handler.failWith = LsException(code, 'x');
        expectError(await postSessions(sessionMap()), code);
      }
    });
  });

  // ---------------------------------------------------------------------------------------
  group('X-LS-Chunk-SHA256 (4.3.1, chunk PUT step 7)', () {
    const path = '/sessions/s1/files/f1/chunks/3';
    final auth = {'authorization': 'Bearer tok-9'};

    test('secure profile: missing header is 400 BAD_REQUEST before the handler runs', () async {
      final r = await rig.request('PUT', path, body: [1, 2, 3], headers: auth);
      expectError(r, LsErrorCode.badRequest);
      expect(rig.handler.count('putChunk'), 0);
    });

    test('secure profile: a malformed hash is 400; a valid one is served and lower-cased', () async {
      for (final bad in ['abc', 'g' * 64, 'a' * 63, 'a' * 65]) {
        final r = await rig.request(
          'PUT',
          path,
          body: [1],
          headers: {...auth, kChunkHashHeader: bad},
        );
        expectError(r, LsErrorCode.badRequest);
      }
      expect(rig.handler.count('putChunk'), 0);
      final bytes = [1, 2, 3, 4];
      final good = sha256Hex(bytes).toUpperCase();
      final ok = await rig.request(
        'PUT',
        path,
        body: bytes,
        headers: {...auth, kChunkHashHeader: good},
      );
      expect(ok.status, 200, reason: ok.text);
      final c = rig.handler.last('putChunk');
      expect(c.chunkSha256, good.toLowerCase());
      expect(c.byteCount, 4);
      expect(c.token, 'tok-9');
    });

    test('the chunk PUT needs no X-LS-Auth in the secure profile (bearer token only)', () async {
      final r = await rig.request(
        'PUT',
        path,
        body: [1],
        headers: {...auth, kChunkHashHeader: 'c' * 64},
      );
      expect(r.status, 200);
    });

    test(
      'plaintext profile: the header stays optional and the handler gets null',
      () async {
        final plain = await P3Rig.start(secure: false);
        addTearDown(plain.stop);
        final r = await plain.request('PUT', path, body: [1, 2], headers: auth);
        expect(r.status, 200, reason: r.text);
        expect(plain.handler.last('putChunk').chunkSha256, isNull);
      },
    );
  });

  // ---------------------------------------------------------------------------------------
  group('POST /sessions/{sid}/sas (4.3.4, 5.1)', () {
    Future<P3Res> sas(Object? json, {P3Peer? as, String sid = 's1'}) =>
        rig.request(
          'POST',
          '/sessions/$sid/sas',
          json: json,
          headers: _json,
          signAs: as ?? alice,
        );

    test('delegates to handler.revealSas with sid, nonce and the proven peer; returns its SessionStatus', () async {
      final r = await sas({'nonce': p3Nonce22}, sid: 'sess-77');
      expect(r.status, 200, reason: r.text);
      expect(r.map['sessionId'], 'sess-77');
      expect(r.map['status'], 'PENDING');
      expect((r.map['sas']! as Map)['nonce'], p3Nonce22);
      final c = rig.handler.last('revealSas');
      expect(c.sessionId, 'sess-77');
      expect(c.nonce, p3Nonce22);
      expect(c.peer!.fingerprint, alice.fp);
      expect(c.peer!.deviceId, alice.deviceId);
      expect(c.peer!.certDer, alice.certDer);
    });

    test(
      'a second signer gets its own peer (no peer leakage between requests)',
      () async {
        await sas({'nonce': p3Nonce22}, as: alice);
        await sas({'nonce': p3Nonce22}, as: p3Bob);
        final peers = rig.handler.calls
            .where((c) => c.method == 'revealSas')
            .map((c) => c.peer!.fingerprint);
        expect(peers.toList(), [alice.fp, p3Bob.fp]);
      },
    );

    test('handler LsExceptions pass through: 401, 404, 409, 410', () async {
      for (final code in [
        LsErrorCode.authInvalid,
        LsErrorCode.notFound,
        LsErrorCode.wrongState,
        LsErrorCode.cancelled,
      ]) {
        rig.handler.failWith = LsException(code, 'm-${code.wire}');
        final r = await sas({'nonce': p3Nonce22});
        expectError(r, code);
        expect(r.error['message'], 'm-${code.wire}');
      }
    });

    test('a body that is not {"nonce": <22 base64url>} is 400 and the handler is not called', () async {
      // SPEC-GAP: LSP-1 lists the 400 under the endpoint; the HTTP layer parses the body, so it checks the shape.
      for (final bad in <Object?>[
        <String, Object?>{},
        {'nonce': 5},
        {'nonce': null},
        {'nonce': 'short'},
        {'nonce': '${p3Nonce22}A'},
        {'nonce': 'ICEiIyQlJicoKSorLC0u!!'},
        [p3Nonce22],
      ]) {
        expectError(await sas(bad), LsErrorCode.badRequest);
      }
      expect(rig.handler.count('revealSas'), 0);
    });

    test('an invalid percent-encoded sid (%ff, not UTF-8) is 400', () async {
      expectError(
        await sas({'nonce': p3Nonce22}, sid: '%ff'),
        LsErrorCode.badRequest,
      );
      expect(rig.handler.count('revealSas'), 0);
    });

    test('plaintext profile: the route does not exist (404 like any unknown route)', () async {
      final plain = await P3Rig.start(secure: false);
      addTearDown(plain.stop);
      final r = await plain.request(
        'POST',
        '/sessions/s1/sas',
        json: {'nonce': p3Nonce22},
        headers: _json,
      );
      expectError(r, LsErrorCode.notFound);
      expect(plain.handler.count('revealSas'), 0);
    });
  });

  // ---------------------------------------------------------------------------------------
  group('POST /pair (4.3.4, 5.3)', () {
    PairRequest req() =>
        PairRequest(sender: alice.info(), nonce: p3Nonce22, mac: 'B' * 43);
    Future<P3Res> pair({P3Peer? as}) => rig.request(
      'POST',
      '/pair',
      json: req().toJson(),
      headers: _json,
      signAs: as ?? alice,
    );

    test('delegates to handler.pair with request, remote address and the proven peer', () async {
      rig.handler.onPair = (r, addr, peer) async => PairResponse(
        accepted: true,
        responder: rig.handler.info,
        nonce: p3Nonce22,
        mac: 'C' * 43,
      );
      final r = await pair();
      expect(r.status, 200, reason: r.text);
      expect(r.map['accepted'], isTrue);
      expect(r.map['nonce'], p3Nonce22);
      expect(r.map['mac'], 'C' * 43);
      expect((r.map['responder']! as Map)['deviceId'], 'dev-receiver');
      final c = rig.handler.last('pair');
      expect(c.pairRequest!.nonce, p3Nonce22);
      expect(c.pairRequest!.mac, 'B' * 43);
      expect(c.pairRequest!.sender.deviceId, alice.deviceId);
      expect(c.remoteAddress, '127.0.0.1');
      expect(c.peer!.fingerprint, alice.fp);
      expect(c.peer!.certDer, alice.certDer);
    });

    test('a declined pairing is a normal 200 {accepted:false}', () async {
      final r = await pair();
      expect(r.status, 200);
      expect(r.map['accepted'], isFalse);
      expect(r.map.containsKey('mac'), isFalse);
    });

    test('a held request (handler answers late) is still delivered', () async {
      rig.handler.onPair = (r, addr, peer) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return PairResponse(accepted: false, responder: rig.handler.info);
      };
      final r = await pair();
      expect(r.status, 200);
    });

    test(
      'handler LsExceptions pass through: 404 (no invite), 409 BUSY, 401, 429',
      () async {
        for (final code in [
          LsErrorCode.notFound,
          LsErrorCode.busy,
          LsErrorCode.authInvalid,
          LsErrorCode.rateLimited,
        ]) {
          rig.handler.failWith = LsException(code, 'x');
          expectError(await pair(), code);
        }
      },
    );

    test('invalid body shape is 400, unknown major is 426; the handler is not called', () async {
      expectError(
        await rig.request(
          'POST',
          '/pair',
          json: {'sender': 1},
          headers: _json,
          signAs: alice,
        ),
        LsErrorCode.badRequest,
      );
      expectError(
        await rig.request(
          'POST',
          '/pair',
          json: <String, Object?>{},
          headers: _json,
          signAs: alice,
        ),
        LsErrorCode.badRequest,
      );
      final m = req().toJson();
      (m['sender']! as Map)['v'] = '2.0';
      expectError(
        await rig.request(
          'POST',
          '/pair',
          json: m,
          headers: _json,
          signAs: alice,
        ),
        LsErrorCode.upgradeRequired,
      );
      expect(rig.handler.count('pair'), 0);
    });

    test('plaintext profile: the route does not exist', () async {
      final plain = await P3Rig.start(secure: false);
      addTearDown(plain.stop);
      final r = await plain.request(
        'POST',
        '/pair',
        json: req().toJson(),
        headers: _json,
      );
      expectError(r, LsErrorCode.notFound);
      expect(plain.handler.count('pair'), 0);
    });
  });

  // ---------------------------------------------------------------------------------------
  group('POST /register and GET /info in the secure profile', () {
    test('register: handler is called and onRegister reports the proven remote; a refused proof reports nothing', () async {
      final seen = <String>[];
      await rig.stop();
      rig = await P3Rig.start(
        onRegister: (peer, addr) => seen.add('${peer.deviceId}@$addr'),
      );
      final b = p3RegisterBody(alice.info());
      final bad = await rig.request(
        'POST',
        '/register',
        body: b,
        headers: _json,
        authHeader: 'junk',
      );
      expectError(bad, LsErrorCode.authInvalid);
      expect(seen, isEmpty);
      final ok = await rig.request(
        'POST',
        '/register',
        body: b,
        headers: _json,
        signAs: alice,
      );
      expect(ok.status, 200);
      expect(seen, ['${alice.deviceId}@127.0.0.1']);
    });

    test(
      'GET /info needs no proof when the receiver is not Contacts-only',
      () async {
        final r = await rig.request('GET', '/info');
        expect(r.status, 200);
        expect(r.map['deviceId'], 'dev-receiver');
      },
    );
  });

  // ---------------------------------------------------------------------------------------
  group('routing is unchanged in the secure profile (4.3.2 Routing)', () {
    test('unknown path, other major, wrong method: 404 envelope', () async {
      for (final (m, p) in [
        ('GET', '/nope'),
        ('DELETE', '/info'),
        ('GET', '/sessions/s1/cancel'),
      ]) {
        expectError(await rig.request(m, p), LsErrorCode.notFound);
      }
      final other = await rig.request('GET', '/info');
      expect(other.status, 200);
    });
  });

  // ---------------------------------------------------------------------------------------
  group('logs carry no secrets (CLAUDE.md, 4.3.6)', () {
    test('proofs, tokens, nonces, signatures and fingerprints never reach a log record', () async {
      final logs = P3LogCapture();
      addTearDown(logs.close);
      final b = p3SessionBody(alice);
      final good = rig.proof(alice, 'POST', '/sessions', b);
      final parts = good.split('.');
      rig.handler.onGetSession = (sid, wait) async =>
          throw StateError('internal detail /secret/dir');
      await rig.request(
        'POST',
        '/sessions',
        body: b,
        headers: _json,
        authHeader: good,
      );
      await rig.request(
        'POST',
        '/sessions',
        body: b,
        headers: _json,
        authHeader: good,
      ); // replay
      await rig.request(
        'POST',
        '/sessions',
        body: b,
        headers: _json,
        authHeader: 'junk-${parts[4]}',
      );
      await rig.request(
        'PUT',
        '/sessions/s1/files/f1/chunks/0',
        body: [1],
        headers: {
          'authorization': 'Bearer secret-token-xyz',
          kChunkHashHeader: 'a' * 64,
        },
      );
      final fault = await rig.request('GET', '/sessions/s1');
      expect(fault.status, 500);
      expect(fault.text, isNot(contains('secret')));

      // Twin: the capture sees the server's own record of that fault (its type only).
      expect(logs.all, contains('StateError'));
      final text = logs.all;
      for (final secret in [
        good,
        parts[1], // certificate
        parts[3], // nonce
        parts[4], // signature
        'secret-token-xyz',
        '/secret/dir',
        alice.fp,
        rig.serverFp,
      ]) {
        expect(
          text,
          isNot(contains(secret)),
          reason: 'secret leaked into a log record',
        );
      }
      expect(
        RegExp('[0-9A-Fa-f]{64}').hasMatch(text),
        isFalse,
        reason: 'full fingerprint or hash in a log',
      );
    });
  });

  // ---------------------------------------------------------------------------------------
  group('stop() in the secure profile keeps the Inc 2 semantics', () {
    Future<P3Raw> hangingTlsRequest() async {
      // A fully valid, signed request whose body only partly arrives: the server must wait for it.
      final b = p3SessionBody(alice);
      final h = rig.proof(alice, 'POST', '/sessions', b);
      final raw = await P3Raw.tls(rig.port);
      raw.write(
        'POST $kApiPrefix/sessions HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n'
        'Content-Length: ${b.length}\r\n$kAuthHeader: $h\r\n\r\n',
      );
      raw.writeBytes(b.sublist(0, 20));
      await raw.socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return raw;
    }

    test(
      'stop() with nothing in flight completes; calling it twice is harmless',
      () async {
        await rig.server.stop().timeout(const Duration(seconds: 3));
        expect(rig.server.isRunning, isFalse);
        await rig.server.stop().timeout(const Duration(seconds: 3));
        await rig.server.stop(force: true).timeout(const Duration(seconds: 3));
      },
    );

    test('graceful stop waits for an in-flight TLS request; stop(force: true) escalates and drops it', () async {
      final raw = await hangingTlsRequest();
      addTearDown(raw.destroy);
      var done = false;
      final stopping = rig.server.stop().then((_) => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(done, isFalse, reason: 'must wait for the in-flight request');
      expect(
        rig.server.isRunning,
        isFalse,
        reason: 'listener is closed at once',
      );
      await rig.server.stop(force: true);
      await stopping.timeout(const Duration(seconds: 5));
      expect(await raw.waitClosed(), isTrue);
    });

    test('a request in flight when stop() begins still gets its answer (graceful)', () async {
      final b = p3SessionBody(alice);
      final h = rig.proof(alice, 'POST', '/sessions', b);
      final raw = await P3Raw.tls(rig.port);
      addTearDown(raw.destroy);
      raw.write(
        'POST $kApiPrefix/sessions HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n'
        'Content-Length: ${b.length}\r\n$kAuthHeader: $h\r\n\r\n',
      );
      raw.writeBytes(b.sublist(0, 20));
      await raw.socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final stopping = rig.server.stop();
      raw.writeBytes(b.sublist(20));
      final head = await raw.waitForHead();
      expect(head, startsWith('HTTP/1.1 202'));
      await stopping.timeout(const Duration(seconds: 5));
    });
  });
}
