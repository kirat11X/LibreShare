// P6b - POST /register in the secure profile: HTTPS, a signed X-LS-Auth proof,
// the announced fingerprint pinned before any HTTP byte is sent, and a peer
// whose answer claims another fingerprint than its certificate is rejected.
//
// Spec: LSP-1 4.2 rule 2 ("[I3] In the secure profile that request carries
// X-LS-Auth"), 0.3 (a secure client never falls back to plain HTTP; it checks
// the fingerprint of the certificate before any HTTP byte), 4.3.6,
// docs/plans/inc3-seams.md data-flow item 7. The proof/pin mechanics live in
// ApiClient (P5): these tests fail until that client is secure-capable too.
//
// New symbols under test (named, optional; defaults keep Inc 2 behaviour):
//   ApiPeerRegistrar(security: SecurityConfig, onCertificate: void Function(Uint8List)?)
import 'dart:convert';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/security/crypto_primitives.dart'
    show sha256Hex;
import 'package:test/test.dart';

import '../helpers/p6b_support.dart';
import '../helpers/p6b_tls_peer.dart';

void main() {
  late P6bPeer server;
  late P6bPeer other;
  late P6bPeer client;
  late List<Uint8List> certs;
  final open = <LoopbackPeer>[];

  setUpAll(() {
    server = P6bPeer('reg-server');
    other = P6bPeer('reg-other');
    client = P6bPeer('reg-client');
  });

  setUp(() => certs = []);

  tearDown(() async {
    for (final p in open) {
      await p.close();
    }
    open.clear();
  });

  Future<LoopbackPeer> tlsPeer({String? infoFingerprint}) async {
    final p = await LoopbackPeer.tls(server, infoFingerprint: infoFingerprint);
    open.add(p);
    return p;
  }

  Future<LoopbackPeer> plainPeer({String? infoFingerprint}) async {
    final p = await LoopbackPeer.plain(
      server,
      infoFingerprint: infoFingerprint,
    );
    open.add(p);
    return p;
  }

  ApiPeerRegistrar registrar({required bool secure}) => ApiPeerRegistrar(
    self: () => secure
        ? client.info()
        : DeviceInfo(deviceId: client.id, alias: 'me', platform: 'linux'),
    timeout: const Duration(seconds: 2),
    security: secure
        ? SecurityConfig.tls(identity: client.key, trust: InMemoryTrustStore())
        : const SecurityConfig.plaintext(),
    onCertificate: certs.add,
  );

  group('secure profile', () {
    test('registers over TLS with a valid X-LS-Auth proof', () async {
      final peer = await tlsPeer();
      final ok = await registrar(secure: true)
          .call(peer.announced(), '127.0.0.1');

      expect(ok, isTrue);
      expect(peer.requests, hasLength(1));
      final r = peer.requests.single;
      expect(r.method, 'POST');
      expect(r.path, '/api/v1/register');
      final sent = jsonDecode(utf8.decode(r.body)) as Map;
      expect(sent['deviceId'], client.id);
      expect(sent['fingerprint'], client.fp);

      // The proof is bound to the server certificate we were talking to.
      final proof = verifyAuthHeader(
        header: r.headers['x-ls-auth'],
        method: 'POST',
        pathAndQuery: r.path,
        body: r.body,
        ownFingerprint: server.fp,
        now: DateTime.now(),
        nonces: NonceCache(),
      );
      expect(proof, isA<AuthOk>());
      expect((proof as AuthOk).peer.fingerprint, client.fp);
      // Channel binding: the same proof is worthless at another server.
      expect(
        verifyAuthHeader(
          header: r.headers['x-ls-auth'],
          method: 'POST',
          pathAndQuery: r.path,
          body: r.body,
          ownFingerprint: other.fp,
          now: DateTime.now(),
          nonces: NonceCache(),
        ),
        isA<AuthFailed>(),
      );
    });

    test(
      'hands over the certificate it saw (so a later bye can be verified)',
      () async {
        final peer = await tlsPeer();
        await registrar(secure: true).call(peer.announced(), '127.0.0.1');
        expect(certs, hasLength(1));
        expect(sha256Hex(certs.single).toUpperCase(), server.fp);
      },
    );

    test('announced fingerprint != presented certificate: refused before any '
        'HTTP byte, reported as false', () async {
      final peer = await tlsPeer();
      // The announce said "other", the listener on that port is "server".
      final ok = await registrar(secure: true)
          .call(peer.announced(fingerprint: other.fp), '127.0.0.1');

      expect(ok, isFalse);
      expect(peer.requests, isEmpty, reason: 'pin checked at the handshake');
      expect(certs, isEmpty);
    });

    test('cert matches the announce but the answer claims another fingerprint: '
        'rejected', () async {
      final peer = await tlsPeer(infoFingerprint: other.fp);
      final ok = await registrar(secure: true)
          .call(peer.announced(), '127.0.0.1');
      expect(ok, isFalse);
      expect(certs, isEmpty, reason: 'unverified certificate is not kept');
    });

    test('a legacy peer (empty announced fingerprint) is never contacted, '
        'over TLS or plain', () async {
      final tlsP = await tlsPeer();
      final plainP = await plainPeer();
      final r = registrar(secure: true);
      expect(
        await r.call(tlsP.announced(fingerprint: ''), '127.0.0.1'),
        isFalse,
      );
      expect(
        await r.call(plainP.announced(fingerprint: ''), '127.0.0.1'),
        isFalse,
      );
      expect(tlsP.requests, isEmpty);
      expect(plainP.requests, isEmpty);
    });

    test('plaintext_server_refused: a plaintext listener behind a valid '
        'announce gets no HTTP request', () async {
      final peer = await plainPeer(infoFingerprint: server.fp);
      final ok = await registrar(secure: true)
          .call(peer.announced(), '127.0.0.1');
      expect(ok, isFalse);
      expect(peer.requests, isEmpty, reason: 'never retried over plain HTTP');
    });

    test('bad inputs still answer false instead of throwing', () async {
      final r = registrar(secure: true);
      final p = server.info(port: 1);
      expect(await r.call(p, 'not-an-ip'), isFalse);
      expect(await r.call(server.info(port: 0), '127.0.0.1'), isFalse);
      expect(
        await r.call(p, '127.0.0.1'),
        isFalse,
        reason: 'nothing listens on port 1',
      );
    });
  });

  group('plaintext profile is unchanged', () {
    test('registers over plain HTTP without any proof header', () async {
      final peer = await plainPeer();
      final ok = await registrar(secure: false)
          .call(peer.announced(fingerprint: ''), '127.0.0.1');
      expect(ok, isTrue);
      expect(peer.requests, hasLength(1));
      expect(peer.requests.single.path, '/api/v1/register');
      expect(peer.requests.single.headers.containsKey('x-ls-auth'), isFalse);
      expect(certs, isEmpty);
    });

    test('a TLS-only listener is not reachable over plain HTTP (twin of the '
        'secure success test)', () async {
      final peer = await tlsPeer();
      final ok = await registrar(secure: false)
          .call(peer.announced(fingerprint: ''), '127.0.0.1');
      expect(ok, isFalse);
      expect(peer.requests, isEmpty);
    });
  });
}
