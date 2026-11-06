// P5 - certificate pinning of the secure ApiClient (LSP-1 0.3 "Transport", 4.3.1 "Channel",
// docs/plans/inc3.md D1, D3, docs/plans/inc3-seams.md data-flow 3 and 6).
//
// The peers are raw TLS listeners that count the bytes they receive (test/helpers/p5_raw_peer.dart):
// "refused before any HTTP byte" is therefore measured, and every such test has a positive twin
// proving the same harness does see requests when the pin matches.
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/security/crypto_primitives.dart'
    show sha256Hex;
import 'package:test/test.dart';

import '../helpers/p5_raw_peer.dart';
import '../helpers/p5_support.dart';

void main() {
  late KeyIdentity me; // the sending device
  late KeyIdentity peerA; // the receiver we pinned
  late KeyIdentity peerB; // somebody else (or a man in the middle)
  late SecurityConfig sec;
  final open = <RawPeer>[];
  final clients = <ApiClient>[];

  setUpAll(() {
    me = newIdentity('p5-me');
    peerA = newIdentity('p5-peer-a');
    peerB = newIdentity('p5-peer-b');
    sec = secureConfig(me);
  });

  Future<RawTlsPeer> tls(IdentityProvider id, {RawHandler? handler}) async {
    final p = await RawTlsPeer.start(id, handler: handler);
    open.add(p);
    return p;
  }

  ApiClient client(RawTlsPeer peer, {String? pin}) {
    final c = secureClient(peer.port, sec, pin: pin);
    clients.add(c);
    return c;
  }

  tearDown(() async {
    for (final c in clients) {
      c.close();
    }
    clients.clear();
    for (final p in open) {
      await p.close();
    }
    open.clear();
  });

  // LSP-1 0.3: "A client compares the fingerprint of the certificate received in the handshake
  // with the pinned one before it sends any HTTP byte and aborts on a mismatch."
  group('pinned peer with another certificate is refused before any HTTP byte', () {
    test(
      'pinned_peer_with_other_certificate_refused_before_any_http_byte',
      () async {
        final peer = await tls(peerB);
        final c = client(peer, pin: peerA.identity.fingerprint);

        Object? error;
        try {
          await c.info();
        } on Object catch (e) {
          error = e;
        }
        expect(error, isA<PeerFingerprintMismatchException>());
        // Distinct from a generic TLS failure so the UI can say "key changed", not "unreachable".
        expect(error, isNot(isA<HandshakeException>()));
        expect(error, isNot(isA<SocketException>()));
        final e = error! as PeerFingerprintMismatchException;
        expect(e.expectedShort, shortFp(peerA.identity.fingerprint));
        expect(e.presentedShort, shortFp(peerB.identity.fingerprint));
        await settle();
        expect(peer.requests, isEmpty);
        expect(peer.bytesReceived, 0);
        expect(
          peer.connections,
          0,
          reason: 'no application connection was served',
        );
      },
    );

    test(
      'control: the same harness sees the request when the pin matches',
      () async {
        final peer = await tls(peerA);
        final c = client(peer, pin: peerA.identity.fingerprint);
        final info = await c.info();
        expect(info.deviceId, 'p5-peer-a');
        expect(peer.requests.map((r) => '$r'), ['GET /api/v1/info']);
        expect(peer.bytesReceived, greaterThan(0));
      },
    );

    // Every operation of the client, not just info(): none may leak a byte (body, token, proof).
    final operations = <String, Future<Object?> Function(ApiClient c)>{
      'info': (c) => c.info(),
      'register': (c) => c.register(infoFor('p5-me', me.identity.fingerprint)),
      'createSession': (c) => c.createSession(
        sampleRequest(infoFor('p5-me', me.identity.fingerprint)),
      ),
      'waitSession': (c) => c.waitSession('sess-1', waitSeconds: 0),
      'fileState': (c) => c.fileState('sess-1', 'f1', token: 'TOKEN-SENTINEL'),
      'putChunk': (c) => c.putChunk(
        'sess-1',
        'f1',
        0,
        Stream.value([1, 2, 3]),
        length: 3,
        chunkSha256: '00' * 32,
        token: 'TOKEN-SENTINEL',
      ),
      'completeFile': (c) =>
          c.completeFile('sess-1', 'f1', token: 'TOKEN-SENTINEL'),
      'finish': (c) => c.finish('sess-1'),
      'cancel': (c) => c.cancel('sess-1'),
      'revealSas': (c) =>
          c.revealSas('sess-1', nonce: 'NONCE-SENTINEL-0123456'),
      'pair': (c) => c.pair(
        PairRequest(
          sender: infoFor('p5-me', me.identity.fingerprint),
          nonce: 'NONCE-SENTINEL-0123456',
          mac: 'MAC-SENTINEL',
        ),
      ),
    };
    for (final entry in operations.entries) {
      test(
        'mismatch on ${entry.key}: zero bytes, PeerFingerprintMismatchException',
        () async {
          final peer = await tls(peerB);
          final c = client(peer, pin: peerA.identity.fingerprint);
          await expectLater(
            entry.value(c),
            throwsA(isA<PeerFingerprintMismatchException>()),
          );
          await settle(50);
          expect(peer.bytesReceived, 0);
          expect(peer.requests, isEmpty);
          expect(peer.receivedText, isNot(contains('SENTINEL')));
        },
      );
    }

    test(
      'a pin that is not a fingerprint never degrades to first contact',
      () async {
        for (final bad in [
          '',
          'ABC',
          'zz' * 32,
          '${peerB.identity.fingerprint}00',
        ]) {
          final peer = await tls(peerB);
          Object? error;
          try {
            // The constructor may reject the value itself (ArgumentError) or the handshake may.
            await secureClient(peer.port, sec, pin: bad).info();
          } on Object catch (e) {
            error = e;
          }
          expect(
            error,
            anyOf(
              isA<ArgumentError>(),
              isA<PeerFingerprintMismatchException>(),
            ),
            reason: 'pin "$bad" must not mean "no pin"',
          );
          await settle(50);
          expect(peer.bytesReceived, 0, reason: 'pin "$bad"');
        }
      },
    );

    test('exception text carries only short fingerprints', () async {
      final peer = await tls(peerB);
      Object? error;
      try {
        await client(peer, pin: peerA.identity.fingerprint).info();
      } on Object catch (e) {
        error = e;
      }
      final text = '$error';
      expect(text, isNot(matches(fullHex)));
      expect(text, isNot(contains(peerA.identity.fingerprint)));
      expect(text, isNot(contains(peerB.identity.fingerprint)));
    });
  });

  // LSP-1 0.3: "pins ignore the validity dates" (certificate valid 24 h before creation for 3650 d).
  group('validity dates are ignored when the certificate is pinned', () {
    test('expired_certificate_still_accepted_when_pinned', () async {
      final expired = newIdentity('p5-expired', now: DateTime.utc(2000, 1, 1));
      final parsed = parseCertificate(expired.identity.certDer);
      expect(parsed.notAfter.isBefore(DateTime.now().toUtc()), isTrue);
      final peer = await tls(expired);
      final c = client(peer, pin: expired.identity.fingerprint);
      expect((await c.info()).deviceId, 'p5-expired');
      expect(peer.requests, hasLength(1));
    });

    test('not-yet-valid certificate is accepted when pinned', () async {
      final future = newIdentity('p5-future', now: DateTime.utc(2100, 1, 1));
      final parsed = parseCertificate(future.identity.certDer);
      expect(parsed.notBefore.isAfter(DateTime.now().toUtc()), isTrue);
      final peer = await tls(future);
      final c = client(peer, pin: future.identity.fingerprint);
      expect((await c.info()).deviceId, 'p5-future');
    });

    test(
      'control: an expired certificate with the WRONG pin is still refused',
      () async {
        final expired = newIdentity(
          'p5-expired2',
          now: DateTime.utc(2000, 1, 1),
        );
        final peer = await tls(expired);
        final c = client(peer, pin: peerA.identity.fingerprint);
        await expectLater(
          c.info(),
          throwsA(isA<PeerFingerprintMismatchException>()),
        );
        await settle(50);
        expect(peer.bytesReceived, 0);
      },
    );
  });

  // LSP-1 0.3: "with no pin it connects, learns the fingerprint and authenticates the server by
  // SAS (5.1)"; contracts: expectedFingerprint == null is first contact, serverFingerprint is the
  // SHA-256 of the DER certificate of the most recent connection.
  group('unpinned first contact', () {
    test('unpinned_first_contact_connects_and_reports_fingerprint', () async {
      final peer = await tls(peerB);
      final c = client(peer);
      expect(
        c.serverFingerprint,
        isNull,
        reason: 'nothing seen before the first request',
      );
      final info = await c.info();
      expect(info.deviceId, 'p5-peer-b');
      final expected = sha256Hex(peerB.identity.certDer).toUpperCase();
      expect(c.serverFingerprint, expected);
      expect(c.serverFingerprint, peerB.identity.fingerprint);
      expect(c.serverFingerprint, matches(RegExp(r'^[0-9A-F]{64}$')));
    });

    test(
      'a pinned client reports the pinned fingerprint after the handshake',
      () async {
        final peer = await tls(peerA);
        final c = client(peer, pin: peerA.identity.fingerprint);
        await c.info();
        expect(c.serverFingerprint, peerA.identity.fingerprint);
      },
    );

    test('a lower-case pin is the same pin', () async {
      final peer = await tls(peerA);
      final c = client(peer, pin: peerA.identity.fingerprint.toLowerCase());
      expect((await c.info()).deviceId, 'p5-peer-a');
    });
  });

  // LSP-1 4.2 rule 7 / seams data-flow 7 (probes) and plan 4.1:
  // "fingerprint_in_info_must_equal_certificate_hash".
  group('fingerprint in /info must equal the certificate hash', () {
    RawHandler lying(IdentityProvider real, String claimed) => (r) {
      if (r.path == '/api/v1/info') {
        return RawResponse.json(
          200,
          infoFor(real.identity.deviceId, claimed).toJson(),
        );
      }
      return RawResponse.error(404, 'NOT_FOUND');
    };

    for (final pinned in [true, false]) {
      test(
        'fingerprint_in_info_must_equal_certificate_hash (${pinned ? 'pinned' : 'first contact'})',
        () async {
          // peerB presents its own certificate but claims to be peerA (impersonation attempt).
          final peer = await tls(
            peerB,
            handler: lying(peerB, peerA.identity.fingerprint),
          );
          final c = client(
            peer,
            pin: pinned ? peerB.identity.fingerprint : null,
          );
          Object? error;
          try {
            await c.info();
          } on Object catch (e) {
            error = e;
          }
          expect(error, isA<PeerFingerprintMismatchException>());
          expect(
            peer.requests,
            hasLength(1),
            reason: 'the lie was actually served',
          );
        },
      );
    }

    test('an empty fingerprint over TLS is a legacy/insecure answer', () async {
      final peer = await tls(peerB, handler: lying(peerB, ''));
      final c = client(peer);
      await expectLater(c.info(), throwsA(isA<InsecurePeerException>()));
    });

    test('control: the truthful /info is accepted', () async {
      final peer = await tls(peerB);
      final info = await client(peer).info();
      expect(info.fingerprint, peerB.identity.fingerprint);
    });
  });

  // Swapped certificate between two requests of one client: a MITM that waits for the first
  // exchange to pass and then takes over the address. TLS keep-alive is disabled on the peers so
  // that each request performs a new handshake.
  group('certificate swapped mid-session', () {
    test('pinned client refuses the swapped certificate; the new peer sees zero bytes', () async {
      final a = await RawTlsPeer.start(peerA, keepAlive: false);
      open.add(a);
      final c = client(a, pin: peerA.identity.fingerprint);
      await c.info();
      expect(a.requests, hasLength(1));
      final port = a.port;
      final b = await RawTlsPeer.start(peerB, port: port, keepAlive: false);
      open.add(b);
      await a.close();
      open.remove(a);
      await expectLater(
        c.info(),
        throwsA(isA<PeerFingerprintMismatchException>()),
      );
      await settle(50);
      expect(b.bytesReceived, 0);
      expect(b.requests, isEmpty);
    });

    test('first-contact client locks onto the first certificate it saw (SPEC-GAP, safer reading)', () async {
      final a = await RawTlsPeer.start(peerA, keepAlive: false);
      open.add(a);
      final c = client(a); // unpinned
      await c.info();
      final firstFp = c.serverFingerprint;
      expect(firstFp, peerA.identity.fingerprint);
      final port = a.port;
      final b = await RawTlsPeer.start(peerB, port: port, keepAlive: false);
      open.add(b);
      await a.close();
      open.remove(a);
      await expectLater(
        c.info(),
        throwsA(isA<PeerFingerprintMismatchException>()),
      );
      await settle(50);
      expect(
        b.bytesReceived,
        0,
        reason: 'a SAS-confirmed peer must not be swapped out',
      );
      expect(c.serverFingerprint, firstFp);
    });

    test(
      'control: the same address with the SAME certificate keeps working',
      () async {
        final a = await RawTlsPeer.start(peerA, keepAlive: false);
        open.add(a);
        final c = client(a, pin: peerA.identity.fingerprint);
        await c.info();
        await c.info();
        expect(a.requests, hasLength(2));
        expect(
          a.connections,
          2,
          reason: 'keepAlive=false: a new handshake per request',
        );
      },
    );
  });
}
