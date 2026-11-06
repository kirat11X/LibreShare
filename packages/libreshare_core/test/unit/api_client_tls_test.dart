// P5 - the secure ApiClient: HTTPS only, the X-LS-Auth proof on the routes that need it, and the
// secure-profile request shapes (LSP-1 0.3, 4.3.1, 4.3.2, 4.3.6, docs/plans/inc3-seams.md
// data-flow 3). The peer is a raw TLS listener that records every request; proofs are checked
// afterwards with P1's verifyAuthHeader against the peer's own fingerprint, exactly like the
// server will.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/security/crypto_primitives.dart'
    show sha256Hex;
import 'package:test/test.dart';

import '../helpers/p5_raw_peer.dart';
import '../helpers/p5_support.dart';

const _nonceR = 'AAECAwQFBgcICQoLDA0ODw'; // 22 b64url chars

RawResponse _canned(RawRequest r, IdentityProvider id) {
  final p = r.path;
  final fp = id.identity.fingerprint;
  if (r.method == 'GET' && p == '/api/v1/info') {
    return RawResponse.json(200, infoFor(id.identity.deviceId, fp).toJson());
  }
  if (r.method == 'POST' && p == '/api/v1/register') {
    return RawResponse.json(200, infoFor(id.identity.deviceId, fp).toJson());
  }
  if (r.method == 'POST' && p == '/api/v1/pair') {
    return RawResponse.json(
      200,
      PairResponse(
        accepted: true,
        responder: infoFor(id.identity.deviceId, fp),
        nonce: _nonceR,
        mac: 'M' * 43,
      ).toJson(),
    );
  }
  if (r.method == 'POST' && p == '/api/v1/sessions') {
    return RawResponse.json(202, statusJson('PENDING', nonce: _nonceR));
  }
  if (r.method == 'POST' && p.endsWith('/sas')) {
    return RawResponse.json(200, statusJson('PENDING', nonce: _nonceR));
  }
  if (p.endsWith('/state')) {
    return RawResponse.json(200, {'receivedRanges': [], 'chunkCount': 1});
  }
  if (r.method == 'PUT') {
    return RawResponse.json(200, {'ack': true, 'index': 0});
  }
  if (p.endsWith('/complete')) {
    return RawResponse.json(200, {'verified': true, 'sha256': '00' * 32});
  }
  if (p.endsWith('/finish')) {
    return RawResponse.json(200, statusJson('COMPLETED'));
  }
  if (p.endsWith('/cancel')) return RawResponse.json(200, {});
  return RawResponse.json(200, statusJson('PENDING'));
}

void main() {
  late KeyIdentity me;
  late KeyIdentity srv;
  late KeyIdentity stranger;
  late SecurityConfig sec;
  late DeviceInfo self;
  final peers = <RawPeer>[];
  final clients = <ApiClient>[];

  setUpAll(() {
    me = newIdentity('p5-me');
    srv = newIdentity('p5-srv');
    stranger = newIdentity('p5-stranger');
    sec = secureConfig(me);
    self = infoFor('p5-me', me.identity.fingerprint);
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

  Future<RawTlsPeer> peer({RawHandler? handler, bool keepAlive = true}) async {
    final p = await RawTlsPeer.start(
      srv,
      keepAlive: keepAlive,
      handler: handler ?? (r) => _canned(r, srv),
    );
    peers.add(p);
    return p;
  }

  ApiClient client(RawTlsPeer p, {String? pin}) {
    final c = secureClient(p.port, sec, pin: pin);
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

  // LSP-1 0.3: secure profile = HTTPS, TLS 1.3 only; plaintext profile = plain HTTP unchanged.
  group('transport', () {
    test('the secure profile talks TLS (a TLS-only peer is reached) and sends HTTP/1.1 inside', () async {
      final p = await peer();
      final c = client(p);
      final info = await c.info();
      expect(info.deviceId, 'p5-srv');
      expect(p.requests.map((r) => '$r'), ['GET /api/v1/info']);
      expect(p.requests.single.header('accept'), 'application/json');
    });

    test('control: the plaintext profile is plain HTTP and sends no proof header at all', () async {
      final plain = await RawPlainPeer.start(
        handler: (r) => r.path == '/api/v1/sessions'
            ? RawResponse.json(200, statusJson('IN_PROGRESS'))
            : RawResponse.json(200, infoFor('legacy', '').toJson()),
      );
      peers.add(plain);
      final c = ApiClient(host: '127.0.0.1', port: plain.port);
      clients.add(c);
      await c.info();
      await c.register(self);
      await c.createSession(sampleRequest(self));
      expect(plain.requests, hasLength(3));
      for (final r in plain.requests) {
        expect(r.header(kAuthHeader), isNull, reason: '${r.method} ${r.path}');
      }
      expect(c.serverFingerprint, isNull);
    });

    test('three requests share one TLS connection and one fingerprint (keep-alive)', () async {
      final p = await peer();
      final c = client(p, pin: srv.identity.fingerprint);
      await c.info();
      await c.createSession(sampleRequest(self));
      await c.waitSession('sess-1', waitSeconds: 0);
      expect(p.connections, 1);
      expect(c.serverFingerprint, srv.identity.fingerprint);
    });

    test(
      'close() is idempotent and a later request does not reach the peer',
      () async {
        final p = await peer();
        final c = client(p);
        await c.info();
        c.close();
        c.close();
        await outcome(c.info());
        expect(p.requests, hasLength(1));
      },
    );
  });

  // LSP-1 4.3.6 "Routes": the proof is required on POST /sessions, /register, /pair and
  // /sessions/{sid}/sas.
  group('X-LS-Auth on the routes that need it', () {
    final proofRoutes = <String, Future<Object?> Function(ApiClient c)>{
      'POST /api/v1/register': (c) =>
          c.register(infoFor('p5-me', me.identity.fingerprint)),
      'POST /api/v1/sessions': (c) => c.createSession(
        sampleRequest(infoFor('p5-me', me.identity.fingerprint)),
      ),
      'POST /api/v1/sessions/sess-1/sas': (c) =>
          c.revealSas('sess-1', nonce: _nonceR),
      'POST /api/v1/pair': (c) => c.pair(
        PairRequest(
          sender: infoFor('p5-me', me.identity.fingerprint),
          nonce: _nonceR,
          mac: 'M' * 43,
        ),
      ),
    };
    for (final pinned in [true, false]) {
      for (final route in proofRoutes.entries) {
        test(
          '${route.key} carries a proof that the receiver accepts (${pinned ? 'pinned' : 'first contact'})',
          () async {
            final p = await peer();
            final c = client(p, pin: pinned ? srv.identity.fingerprint : null);
            await route.value(c);
            expect(
              '${p.requests.last.method} ${p.requests.last.path}',
              route.key,
            );
            final res = ProofChecker(srv.identity.fingerprint)
                .check(p.requests.last);
            expect(res, isA<AuthOk>(), reason: '$res');
            final peerId = (res as AuthOk).peer;
            expect(peerId.fingerprint, me.identity.fingerprint);
            expect(peerId.deviceId, 'p5-me');
          },
        );
      }
    }

    test(
      'the header grammar is v1.<cert>.<ts>.<nonce>.<sig> and at most 4 KiB',
      () async {
        final p = await peer();
        await client(p).createSession(sampleRequest(self));
        final h = p.requests.single.header(kAuthHeader)!;
        expect(h, startsWith('v1.'));
        expect(h.split('.'), hasLength(5));
        expect(h.length, lessThanOrEqualTo(4096));
        expect(
          p.requests.single.headers.keys.where((k) => k == kAuthHeader),
          hasLength(1),
        );
      },
    );

    // 4.3.6: serverFp = fingerprint of the certificate seen in the handshake of THIS connection.
    test(
      'the proof is bound to the server certificate of this connection',
      () async {
        final p = await peer();
        await client(p).createSession(
          sampleRequest(self),
        ); // first contact: fp learned in handshake
        final r = p.requests.single;
        expect(ProofChecker(srv.identity.fingerprint).check(r), isA<AuthOk>());
        // Twin: a receiver with another fingerprint (the relay case) rejects the same bytes.
        final relayed = ProofChecker(srv.identity.fingerprint)
            .check(r, asFingerprint: stranger.identity.fingerprint);
        expect(relayed, isA<AuthFailed>());
        expect((relayed as AuthFailed).reason, AuthFailure.badSignature);
      },
    );

    test(
      'the proof covers the exact body bytes and the exact target',
      () async {
        final p = await peer();
        await client(p).createSession(sampleRequest(self));
        final r = p.requests.single;
        RawRequest tweaked({Uint8List? body, String? target}) => RawRequest(
          method: r.method,
          target: target ?? r.target,
          headers: r.headers,
          body: body ?? r.body,
          connection: r.connection,
        );
        ProofChecker checker() => ProofChecker(srv.identity.fingerprint);
        expect(checker().check(r), isA<AuthOk>());
        final flipped = Uint8List.fromList(r.body)..[r.body.length - 3] ^= 1;
        expect(checker().check(tweaked(body: flipped)), isA<AuthFailed>());
        expect(
          checker().check(tweaked(target: '/api/v1/sessions?x=1')),
          isA<AuthFailed>(),
        );
        expect(
          checker().check(tweaked(target: '/api/v1/register')),
          isA<AuthFailed>(),
        );
      },
    );

    test('the signed target is the target as sent, also for ids that need percent-encoding', () async {
      final p = await peer();
      await client(p).revealSas('a b%c/ü', nonce: _nonceR);
      final r = p.requests.single;
      expect(r.target, startsWith('/api/v1/sessions/'));
      expect(r.target, isNot(contains(' ')));
      expect(ProofChecker(srv.identity.fingerprint).check(r), isA<AuthOk>());
    });

    test('every request gets a fresh nonce and a current timestamp', () async {
      final p = await peer();
      final c = client(p);
      final before = DateTime.now().toUtc().millisecondsSinceEpoch;
      for (var i = 0; i < 5; i++) {
        await c.createSession(sampleRequest(self));
      }
      final after = DateTime.now().toUtc().millisecondsSinceEpoch;
      final checker = ProofChecker(srv.identity.fingerprint);
      final nonces = <String>{};
      for (final r in p.requests) {
        // A shared replay cache accepts each header once: a repeated nonce would be AuthFailed.
        expect(checker.check(r), isA<AuthOk>());
        final parts = proofParts(r.header(kAuthHeader)!);
        nonces.add(parts.nonce);
        expect(parts.ts, inInclusiveRange(before - 2000, after + 2000));
      }
      expect(nonces, hasLength(5));
      // Control: replaying a captured header IS caught by the same checker.
      expect(
        (checker.check(p.requests.first) as AuthFailed).reason,
        AuthFailure.replayed,
      );
    });

    // 4.3.6 "Routes": GET /info needs a proof only on a Contacts-only receiver, and "a client
    // attaches it only to a peer it has pinned, so its identity is never offered to a server that
    // is not yet authenticated".
    test('GET /info: no proof to an unpinned server', () async {
      final p = await peer();
      await client(p).info();
      expect(p.requests.single.header(kAuthHeader), isNull);
    });

    test('GET /info: a pinned server gets a valid proof (SPEC-GAP: always, since the client cannot know it is Contacts-only)', () async {
      final p = await peer();
      await client(p, pin: srv.identity.fingerprint).info();
      final r = p.requests.single;
      expect(r.header(kAuthHeader), isNotNull);
      expect(ProofChecker(srv.identity.fingerprint).check(r), isA<AuthOk>());
    });

    // 4.3.6 "Routes": these use the session id or the file token instead.
    test('routes that do not use a proof carry none', () async {
      final p = await peer();
      final c = client(p, pin: srv.identity.fingerprint);
      await c.waitSession('sess-1', waitSeconds: 0);
      await c.fileState('sess-1', 'f1', token: 'tok');
      await c.putChunk(
        'sess-1',
        'f1',
        0,
        Stream.value([1, 2, 3]),
        length: 3,
        chunkSha256: sha256Hex([1, 2, 3]),
        token: 'tok',
      );
      await c.completeFile('sess-1', 'f1', token: 'tok');
      await c.finish('sess-1');
      await c.cancel('sess-1');
      expect(p.requests, hasLength(6));
      for (final r in p.requests) {
        expect(r.header(kAuthHeader), isNull, reason: '${r.method} ${r.path}');
      }
    });
  });

  group('request and response shapes over TLS', () {
    test('revealSas posts {"nonce":...} and returns the PENDING status with the receiver nonce', () async {
      final p = await peer();
      final st = await client(p).revealSas('sess-1', nonce: 'N' * 22);
      final r = p.requests.single;
      expect(r.method, 'POST');
      expect(r.path, '/api/v1/sessions/sess-1/sas');
      expect(r.json, {'nonce': 'N' * 22});
      expect(r.header('content-type'), contains('application/json'));
      expect(st.status, TransferStatus.pending);
      expect(st.sas?.nonce, _nonceR);
    });

    test('pair posts the PairRequest and parses the PairResponse', () async {
      final p = await peer();
      final req = PairRequest(sender: self, nonce: 'N' * 22, mac: 'A' * 43);
      final res = await client(p).pair(req);
      final r = p.requests.single;
      expect(r.path, '/api/v1/pair');
      expect(r.json, req.toJson());
      expect(res.accepted, isTrue);
      expect(res.nonce, _nonceR);
      expect(res.responder.deviceId, 'p5-srv');
    });

    test(
      'createSession carries sasCommit when given and parses sas.nonce',
      () async {
        final p = await peer();
        final st = await client(p)
            .createSession(sampleRequest(self, sasCommit: 'C' * 43));
        expect((p.requests.single.json! as Map)['sasCommit'], 'C' * 43);
        expect(st.sas?.nonce, _nonceR);
        expect(st.status, TransferStatus.pending);
      },
    );

    test(
      'a chunk PUT keeps its bytes, length and hash header over TLS',
      () async {
        final p = await peer();
        final bytes = List<int>.generate(70000, (i) => i & 0xFF);
        final hash = sha256Hex(bytes);
        await client(p).putChunk(
          'sess-1',
          'f1',
          2,
          Stream.fromIterable([bytes.sublist(0, 30000), bytes.sublist(30000)]),
          length: bytes.length,
          chunkSha256: hash,
          token: 'tok',
        );
        final r = p.requests.single;
        expect(r.method, 'PUT');
        expect(r.path, '/api/v1/sessions/sess-1/files/f1/chunks/2');
        expect(r.body, bytes);
        expect(r.header('content-length'), '${bytes.length}');
        expect(r.header(kChunkHashHeader), hash);
        expect(r.header('authorization'), 'Bearer tok');
      },
    );
  });

  // 4.3.5: a refused proof is an ordinary LsException; the pin-mismatch exception is only for the
  // handshake.
  group('wire errors stay LsException', () {
    for (final (status, code, expected) in [
      (401, 'AUTH_INVALID', LsErrorCode.authInvalid),
      (403, 'KEY_CHANGED', LsErrorCode.keyChanged),
      (403, 'BLOCKED', LsErrorCode.blocked),
      (401, 'PIN_REQUIRED', LsErrorCode.pinRequired),
      (404, 'NOT_FOUND', LsErrorCode.notFound),
    ]) {
      test('$status $code', () async {
        final p = await peer(handler: (r) => RawResponse.error(status, code));
        final err = await outcome(
          client(
            p,
            pin: srv.identity.fingerprint,
          ).createSession(sampleRequest(self)),
        );
        expect(err, isA<LsException>().having((e) => e.code, 'code', expected));
        expect(err, isNot(isA<PeerFingerprintMismatchException>()));
        expect(err, isNot(isA<InsecurePeerException>()));
      });
    }

    test(
      'a body that is not JSON is INTERNAL, not a security exception',
      () async {
        final p = await peer(
          handler: (r) => RawResponse(200, body: utf8.encode('<html>')),
        );
        final err = await outcome(client(p).createSession(sampleRequest(self)));
        expect(
          err,
          isA<LsException>().having(
            (e) => e.code,
            'code',
            LsErrorCode.internal,
          ),
        );
      },
    );
  });
}
