// X-LS-Auth through the real TLS server. Spec: LSP-1 4.3.1 (X-LS-Auth row), 4.3.4 (secure order,
// step 4), 4.3.5 (AUTH_INVALID), 4.3.6 (grammar, receiver checks, clock, routes).
//
// Every failure must be 401 AUTH_INVALID with one fixed generic message that does not say which
// check failed, with a `Date` header, and the handler must not be called.
import 'dart:convert';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p3_secure_rig.dart';

void main() {
  late P3Rig rig;

  setUp(() async => rig = await P3Rig.start());
  tearDown(() => rig.stop());

  final alice = p3Alice;
  final bob = p3Bob;

  List<int> body() => p3SessionBody(alice);

  Future<P3Res> postWith(String? header, {List<int>? b}) => rig.request(
    'POST',
    '/sessions',
    body: b ?? body(),
    headers: {'content-type': 'application/json'},
    authHeader: header,
  );

  void expectAuthInvalid(P3Res r, {String? why}) {
    expect(r.status, 401, reason: why ?? r.text);
    expect(r.header('content-type'), contains('application/json'));
    expect(r.error['code'], 'AUTH_INVALID', reason: why);
    expect(r.error['retryable'], isFalse);
    expect(r.date, isNotNull, reason: 'Date lets a client correct its clock');
  }

  // 4.3.6: a valid proof for exactly this request is accepted and identifies the signer.
  group('valid proof (4.3.6)', () {
    test('is accepted; the handler sees the proven peer', () async {
      final r = await rig.postSession(alice);
      expect(r.status, 202, reason: r.text);
      expect(rig.handler.count('createAuthenticatedSession'), 1);
      final peer = rig.handler.last('createAuthenticatedSession').peer!;
      expect(peer.fingerprint, alice.fp);
      expect(peer.deviceId, alice.deviceId);
      expect(peer.certDer, alice.certDer);
    });

    test('a proof of a never-seen identity is valid too (trust is not the server layer)', () async {
      final r = await rig.postSession(p3Mallory);
      expect(r.status, 202);
      expect(
        rig.handler.last('createAuthenticatedSession').peer!.fingerprint,
        p3Mallory.fp,
      );
    });

    test('clock skew inside the window is tolerated (+-110 s)', () async {
      for (final skew in [-110, 110]) {
        final b = body();
        final h = rig.proof(
          alice,
          'POST',
          '/sessions',
          b,
          now: DateTime.now().add(Duration(seconds: skew)),
        );
        expect((await postWith(h, b: b)).status, 202, reason: 'skew $skew s');
      }
    });
  });

  // 4.3.6 check 4: M is rebuilt from what the receiver saw; every bent field is refused.
  group('a proof is bound to this request (4.3.6 checks 3-4)', () {
    final b = p3SessionBody(alice);

    test('wrong path', () async {
      final h = rig.proof(
        alice,
        'POST',
        '/sessions',
        b,
        signedPath: '$kApiPrefix/register',
      );
      expectAuthInvalid(await postWith(h, b: b));
      expect(rig.handler.calls, isEmpty);
    });

    test('wrong method', () async {
      final h = rig.proof(alice, 'POST', '/sessions', b, signedMethod: 'PUT');
      expectAuthInvalid(await postWith(h, b: b));
      expect(rig.handler.calls, isEmpty);
    });

    test('wrong body hash (proof made over another body)', () async {
      final other = p3SessionBody(alice, files: 2);
      final h = rig.proof(alice, 'POST', '/sessions', b, signedBody: other);
      expectAuthInvalid(await postWith(h, b: b));
      expect(rig.handler.calls, isEmpty);
    });

    test('one flipped body byte after signing', () async {
      final h = rig.proof(alice, 'POST', '/sessions', b);
      final tampered = List<int>.of(b)..[b.length ~/ 2] ^= 1;
      expectAuthInvalid(await postWith(h, b: tampered));
      expect(rig.handler.calls, isEmpty);
    });

    test('proof made for another server (channel binding)', () async {
      final h = rig.proof(
        alice,
        'POST',
        '/sessions',
        b,
        serverFp: p3OtherServerKey.identity.fingerprint,
      );
      expectAuthInvalid(await postWith(h, b: b));
      expect(rig.handler.calls, isEmpty);
      // Twin: the same request bound to THIS server's fingerprint is served.
      expect((await rig.postSession(alice, body: b)).status, 202);
    });

    test('the query string is part of the signed target', () async {
      final bad = rig.proof(alice, 'POST', '/sessions', b);
      final r1 = await rig.request(
        'POST',
        '/sessions?x=1',
        body: b,
        headers: {'content-type': 'application/json'},
        authHeader: bad,
      );
      expectAuthInvalid(r1);
      final good = rig.proof(alice, 'POST', '/sessions?x=1', b);
      final r2 = await rig.request(
        'POST',
        '/sessions?x=1',
        body: b,
        headers: {'content-type': 'application/json'},
        authHeader: good,
      );
      expect(r2.status, 202, reason: r2.text);
    });

    test(
      'the target is signed as sent, not decoded (percent-encoding is kept)',
      () async {
        // %3A decodes to ':'; the handler must see sid 'a:b' while the proof names the encoded form.
        final sasBody = utf8.encode(jsonEncode({'nonce': p3Nonce22}));
        final decodedForm = rig.proof(
          alice,
          'POST',
          '/sessions/a:b/sas',
          sasBody,
        );
        expectAuthInvalid(
          await rig.request(
            'POST',
            '/sessions/a%3Ab/sas',
            body: sasBody,
            headers: {'content-type': 'application/json'},
            authHeader: decodedForm,
          ),
          why: 'proof over the decoded path must not verify',
        );
        final encodedForm = rig.proof(
          alice,
          'POST',
          '/sessions/a%3Ab/sas',
          sasBody,
        );
        final ok = await rig.request(
          'POST',
          '/sessions/a%3Ab/sas',
          body: sasBody,
          headers: {'content-type': 'application/json'},
          authHeader: encodedForm,
        );
        expect(ok.status, 200, reason: ok.text);
        expect(rig.handler.last('revealSas').sessionId, 'a:b');
      },
    );
  });

  group('timestamp window kAuthWindow = 120 s (4.3.6 check 3)', () {
    for (final skew in [-130, 130, -3600, 3600]) {
      test('${skew > 0 ? 'future' : 'stale'} by $skew s is refused', () async {
        final b = body();
        final h = rig.proof(
          alice,
          'POST',
          '/sessions',
          b,
          now: DateTime.now().add(Duration(seconds: skew)),
        );
        expectAuthInvalid(await postWith(h, b: b));
        expect(rig.handler.calls, isEmpty);
      });
    }
  });

  group('replay: (client fingerprint, nonce) is single-use per server (4.3.6 check 5)', () {
    test('the same header twice: first served, second 401', () async {
      final b = body();
      final h = rig.proof(alice, 'POST', '/sessions', b);
      expect((await postWith(h, b: b)).status, 202);
      expectAuthInvalid(await postWith(h, b: b));
      expect(rig.handler.count('createAuthenticatedSession'), 1);
    });

    test(
      'the cache is server-wide: a replay on a brand-new connection is refused',
      () async {
        final b = body();
        final h = rig.proof(alice, 'POST', '/sessions', b);
        expect((await postWith(h, b: b)).status, 202);
        rig.dropConnections();
        expectAuthInvalid(await postWith(h, b: b));
      },
    );

    test('a fresh nonce is accepted (positive twin)', () async {
      final b = body();
      expect((await rig.postSession(alice, body: b)).status, 202);
      expect((await rig.postSession(alice, body: b)).status, 202);
      expect(rig.handler.count('createAuthenticatedSession'), 2);
    });

    test('a refused proof does not burn its nonce (only verified proofs are remembered)', () async {
      final b = body();
      final h = rig.proof(alice, 'POST', '/sessions', b);
      final tampered = List<int>.of(b)..[10] ^= 1;
      expectAuthInvalid(await postWith(h, b: tampered));
      expect(
        (await postWith(h, b: b)).status,
        202,
        reason: 'genuine request must still pass',
      );
    });

    test('same nonce from two different clients does not collide', () async {
      final n = Uint8List.fromList(List.generate(16, (i) => i + 1));
      for (final who in [alice, bob]) {
        final b = p3SessionBody(who);
        final h = rig.proof(who, 'POST', '/sessions', b, nonce: n);
        expect((await postWith(h, b: b)).status, 202, reason: who.deviceId);
      }
    });
  });

  group(
    'malformed, truncated and forged headers (4.3.6 grammar, checks 1-2)',
    () {
      late String valid;
      setUp(() => valid = rig.proof(alice, 'POST', '/sessions', body()));

      final cases = <String, String Function(String)>{
        'empty value': (v) => '',
        'plain garbage': (v) => 'abc',
        'only the version tag': (v) => 'v1',
        'truncated by 5 characters': (v) => v.substring(0, v.length - 5),
        'truncated to the first half': (v) => v.substring(0, v.length ~/ 2),
        'last part dropped': (v) => v.substring(0, v.lastIndexOf('.')),
        'extra part appended': (v) => '$v.AAAA',
        'unknown version': (v) => 'v2${v.substring(2)}',
        'upper-cased version': (v) => 'V1${v.substring(2)}',
        'padded signature': (v) => '$v=',
        'space inside': (v) => v.replaceFirst('.', '. '),
        'non-base64url character in the cert': (v) => v.replaceFirst('.', '.!'),
        'signature flipped in one character': (v) {
          final i = v.length - 3;
          final c = v[i] == 'A' ? 'B' : 'A';
          return v.substring(0, i) + c + v.substring(i + 1);
        },
        'timestamp with a leading zero': (v) {
          final p = v.split('.');
          p[2] = '0${p[2]}';
          return p.join('.');
        },
        'timestamp not a number': (v) {
          final p = v.split('.');
          p[2] = 'now';
          return p.join('.');
        },
        'nonce too short': (v) {
          final p = v.split('.');
          p[3] = p[3].substring(0, 20);
          return p.join('.');
        },
        'signature too short': (v) {
          final p = v.split('.');
          p[4] = p[4].substring(0, 80);
          return p.join('.');
        },
        'oversized (> 4 KiB)': (v) => '$v${'A' * 4200}',
      };

      for (final e in cases.entries) {
        test(e.key, () async {
          final r = await postWith(e.value(valid));
          expectAuthInvalid(r);
          expect(rig.handler.calls, isEmpty);
        });
      }

      test('certificate of one client, signature of another', () async {
        final b = body();
        final a = rig.proof(alice, 'POST', '/sessions', b).split('.');
        final m = rig.proof(p3Mallory, 'POST', '/sessions', b).split('.');
        // cert of Alice, ts+nonce+sig of Mallory
        final forged = [a[0], a[1], m[2], m[3], m[4]].join('.');
        expectAuthInvalid(await postWith(forged, b: b));
        // cert of Mallory, signature of Alice
        final forged2 = [m[0], m[1], a[2], a[3], a[4]].join('.');
        expectAuthInvalid(await postWith(forged2, b: b));
        expect(rig.handler.calls, isEmpty);
      });

      test('the header twice is refused (it must be present once)', () async {
        final b = body();
        final h1 = rig.proof(alice, 'POST', '/sessions', b);
        final h2 = rig.proof(alice, 'POST', '/sessions', b);
        final raw = await P3Raw.tls(rig.port);
        addTearDown(raw.destroy);
        raw.write(
          'POST $kApiPrefix/sessions HTTP/1.1\r\nHost: x\r\n'
          'Content-Type: application/json\r\nContent-Length: ${b.length}\r\n'
          'X-LS-Auth: $h1\r\nX-LS-Auth: $h2\r\n\r\n',
        );
        raw.writeBytes(b);
        final head = await raw.waitForHead();
        expect(head, startsWith('HTTP/1.1 401'));
        expect(head, contains('AUTH_INVALID'));
        expect(rig.handler.calls, isEmpty);
      });

      test('no header at all', () async {
        final r = await postWith(null);
        expectAuthInvalid(r);
        expect(rig.handler.calls, isEmpty);
      });
    },
  );

  // 4.3.5 / 4.3.6: the refusal never says which check failed, and never echoes input.
  group('generic answer: no oracle about which check failed', () {
    test('all failure kinds give the same status, headers (but Date) and body bytes', () async {
      final b = body();
      final other = p3SessionBody(alice, files: 3);
      final ok = rig.proof(alice, 'POST', '/sessions', b);
      final attempts = <String, Future<P3Res> Function()>{
        'missing': () => postWith(null, b: b),
        'garbage': () => postWith('v1.x.y.z.w', b: b),
        'truncated': () => postWith(ok.substring(0, ok.length - 9), b: b),
        'wrong path': () => postWith(
          rig.proof(
            alice,
            'POST',
            '/sessions',
            b,
            signedPath: '$kApiPrefix/pair',
          ),
          b: b,
        ),
        'wrong method': () => postWith(
          rig.proof(alice, 'POST', '/sessions', b, signedMethod: 'GET'),
          b: b,
        ),
        'wrong body': () => postWith(
          rig.proof(alice, 'POST', '/sessions', b, signedBody: other),
          b: b,
        ),
        'stale': () => postWith(
          rig.proof(
            alice,
            'POST',
            '/sessions',
            b,
            now: DateTime.now().subtract(const Duration(hours: 1)),
          ),
          b: b,
        ),
        'future': () => postWith(
          rig.proof(
            alice,
            'POST',
            '/sessions',
            b,
            now: DateTime.now().add(const Duration(hours: 1)),
          ),
          b: b,
        ),
        'other server': () => postWith(
          rig.proof(
            alice,
            'POST',
            '/sessions',
            b,
            serverFp: p3OtherServerKey.identity.fingerprint,
          ),
          b: b,
        ),
      };
      // replayed: needs a first use
      expect((await postWith(ok, b: b)).status, 202);
      attempts['replayed'] = () => postWith(ok, b: b);

      final bodies = <String>{};
      final headerSets = <String>{};
      for (final e in attempts.entries) {
        final r = await e.value();
        expectAuthInvalid(r, why: e.key);
        bodies.add(utf8.decode(r.bytes));
        headerSets.add(jsonEncode(r.headersWithoutDate));
      }
      expect(bodies, hasLength(1), reason: 'bodies differ: $bodies');
      expect(headerSets, hasLength(1), reason: 'headers differ: $headerSets');
    });

    test(
      'the message names no check and echoes neither input nor fingerprints',
      () async {
        final b = body();
        final h = rig.proof(
          alice,
          'POST',
          '/sessions',
          b,
          now: DateTime.now().subtract(const Duration(hours: 1)),
        );
        final r = await postWith(h, b: b);
        final message = (r.error['message']! as String).toLowerCase();
        for (final word in [
          'signature',
          'replay',
          'stale',
          'expired',
          'timestamp',
          'clock',
          'nonce',
          'fingerprint',
          'certificate',
          'path',
          'method',
          'hash',
          'server',
          'skew',
        ]) {
          expect(
            message,
            isNot(contains(word)),
            reason: 'message leaks the check: $message',
          );
        }
        final text = r.text;
        expect(text, isNot(contains(alice.fp)));
        expect(text, isNot(contains(rig.serverFp)));
        expect(text, isNot(contains(h.split('.')[3])));
        expect(message, isNotEmpty);
      },
    );
  });

  // 4.3.6 Routes table and 4.3.2: which routes need a proof.
  group('routes that need a proof (4.3.6 Routes)', () {
    final sasBody = utf8.encode(jsonEncode({'nonce': p3Nonce22}));
    late Map<String, ({String method, String path, List<int> body})> routes;
    setUp(() {
      routes = {
        'POST /sessions': (method: 'POST', path: '/sessions', body: body()),
        'POST /register': (
          method: 'POST',
          path: '/register',
          body: p3RegisterBody(alice.info()),
        ),
        'POST /sessions/{sid}/sas': (
          method: 'POST',
          path: '/sessions/s1/sas',
          body: sasBody,
        ),
        'POST /pair': (
          method: 'POST',
          path: '/pair',
          body: utf8.encode(
            jsonEncode(
              PairRequest(
                sender: alice.info(),
                nonce: p3Nonce22,
                mac: 'A' * 43,
              ).toJson(),
            ),
          ),
        ),
      };
    });

    test('without X-LS-Auth each is 401 AUTH_INVALID and never reaches the handler', () async {
      for (final e in routes.entries) {
        final r = await rig.request(
          e.value.method,
          e.value.path,
          body: e.value.body,
          headers: {'content-type': 'application/json'},
        );
        expectAuthInvalid(r, why: e.key);
      }
      expect(rig.handler.calls, isEmpty);
    });

    test(
      'with a valid proof each is served (twin: the harness can see success)',
      () async {
        for (final e in routes.entries) {
          final r = await rig.request(
            e.value.method,
            e.value.path,
            body: e.value.body,
            headers: {'content-type': 'application/json'},
            signAs: alice,
          );
          expect(r.status, anyOf(200, 202), reason: '${e.key}: ${r.text}');
        }
        expect(
          rig.handler.names,
          containsAll([
            'createAuthenticatedSession',
            'register',
            'revealSas',
            'pair',
          ]),
        );
      },
    );

    test('a proof made for one route does not open another', () async {
      final sessions = routes['POST /sessions']!;
      final h = rig.proof(alice, 'POST', sessions.path, sessions.body);
      final r = await rig.request(
        'POST',
        '/sessions/s1/sas',
        body: sasBody,
        headers: {'content-type': 'application/json'},
        authHeader: h,
      );
      expectAuthInvalid(r);
      expect(rig.handler.calls, isEmpty);
    });

    test('POST /register: a non-empty DeviceInfo.fingerprint must equal the proven one', () async {
      final b = p3RegisterBody(alice.info(fingerprint: bob.fp));
      final r = await rig.request(
        'POST',
        '/register',
        body: b,
        headers: {'content-type': 'application/json'},
        signAs: alice,
      );
      expectAuthInvalid(r);
      expect(rig.handler.count('register'), 0);
      final empty = await rig.request(
        'POST',
        '/register',
        body: p3RegisterBody(alice.info(fingerprint: '')),
        headers: {'content-type': 'application/json'},
        signAs: alice,
      );
      expect(empty.status, 200, reason: empty.text);
    });
  });

  // 4.3.6 Routes: the other routes do not use the header; a junk header must not break them.
  group('routes that do not use a proof', () {
    // SPEC-GAP: "not used" is read as "ignored": a junk or valid header there changes nothing.
    test(
      'GET /info, GET /sessions/{sid}, finish, cancel ignore a junk X-LS-Auth',
      () async {
        for (final (method, path) in [
          ('GET', '/info'),
          ('GET', '/sessions/s1?wait=0'),
          ('POST', '/sessions/s1/finish'),
          ('POST', '/sessions/s1/cancel'),
        ]) {
          final r = await rig.request(method, path, authHeader: 'junk');
          expect(r.status, 200, reason: '$method $path: ${r.text}');
        }
      },
    );

    test('chunk PUT needs the bearer token only', () async {
      final r = await rig.request(
        'PUT',
        '/sessions/s1/files/f1/chunks/0',
        body: [1, 2, 3],
        headers: {
          'authorization': 'Bearer tok-1',
          kChunkHashHeader: 'a' * 64,
          'content-type': 'application/octet-stream',
        },
      );
      expect(r.status, 200, reason: r.text);
    });
  });
}
