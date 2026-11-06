// P5 - adversarial review by the verifying tester (2026-11-05). Added AFTER the coder's work; the
// existing P5 tests are untouched. Tests marked [RED] fail against the code as reviewed and are
// what the P5 coder must make green; the others are guards for mutations the earlier tests missed.
//
// Spec: LSP-1 0.3 (pin before any HTTP byte; secure client never falls back), 4.7, 5.1;
// docs/plans/inc3-seams.md data-flow 6 ("a secure client never falls back from TLS to HTTP").
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p56v_support.dart';
import '../helpers/p5_fake_secure_peer.dart';
import '../helpers/p5_raw_peer.dart';
import '../helpers/p5_support.dart';
import '../helpers/test_data.dart';

final RegExp _hex64 = RegExp(r'[0-9A-Fa-f]{64}');

/// A receiver that answers the reveal with something else than the unchanged PENDING status and
/// the Nr it announced in the 202 (LSP-1 5.1: "Nr ... does not change").
class _ShiftyReceiver extends FakeSecurePeer {
  _ShiftyReceiver(
    this.how, {
    required super.senderFp,
    required super.receiverFp,
  });

  final String how;

  @override
  Future<SessionStatus> revealSas(
    String sessionId, {
    required String nonce,
  }) async {
    await super.revealSas(sessionId, nonce: nonce);
    switch (how) {
      case 'other-nr':
        return SessionStatus(
          sessionId: sessionId,
          status: TransferStatus.pending,
          sas: SasChallenge(nonce: b64urlEncode(Uint8List(16))),
        );
      case 'no-sas':
        return SessionStatus(
          sessionId: sessionId,
          status: TransferStatus.pending,
        );
      default: // 'accepted-at-once'
        return SessionStatus(
          sessionId: sessionId,
          status: TransferStatus.inProgress,
          acceptedFiles: {
            for (final f in request!.files)
              f.fileId: AcceptedFile(token: 'tok-${f.fileId}'),
          },
        );
    }
  }
}

bool _opensslPresent() {
  try {
    return Process.runSync('openssl', ['version']).exitCode == 0;
  } on Object {
    return false;
  }
}

void main() {
  late KeyIdentity me;
  late KeyIdentity peerA;
  late KeyIdentity peerB;
  late SecurityConfig sec;
  final open = <RawPeer>[];
  final clients = <ApiClient>[];

  setUpAll(() {
    me = newIdentity('p5r-me');
    peerA = newIdentity('p5r-peer-a');
    peerB = newIdentity('p5r-peer-b');
    sec = secureConfig(me);
  });

  Future<RawTlsPeer> tls(IdentityProvider id, {RawHandler? handler}) async {
    final p = await RawTlsPeer.start(id, handler: handler);
    open.add(p);
    return p;
  }

  ApiClient client(int port, {String? pin}) {
    final c = secureClient(port, sec, pin: pin);
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

  Future<Object?> errorOf(Future<Object?> f) =>
      f.then<Object?>((_) => null, onError: (Object e) => e);

  group('pin check covers every connection', () {
    // Guard (not red: dart:io delivers the failures one by one). The mismatch is handed from the certificate callback to the failing request through a
    // single shared field. With several connections opening at once every callback runs before
    // the first failure is delivered, so only one request gets the mismatch and the others are
    // reported as InsecurePeerException ("peer does not offer the secure profile") for a key
    // change. Each request must report its own cause.
    test(
      'concurrent_requests_to_a_swapped_certificate_all_report_the_mismatch',
      () async {
        final peer = await tls(peerB);
        final c = client(peer.port, pin: peerA.identity.fingerprint);
        final errors = await Future.wait([
          for (var i = 0; i < 12; i++) errorOf(c.info()),
          errorOf(c.info()),
          errorOf(c.finish('s1')),
          errorOf(c.cancel('s1')),
          errorOf(c.waitSession('s1', waitSeconds: 0)),
          errorOf(c.createSession(sampleRequest(infoFor('p5r-me', 'AA' * 32)))),
          errorOf(c.register(infoFor('p5r-me', me.identity.fingerprint))),
        ]);
        for (var i = 0; i < errors.length; i++) {
          expect(
            errors[i],
            isA<PeerFingerprintMismatchException>(),
            reason: 'request #$i: ${errors[i].runtimeType}',
          );
        }
        await settle();
        expect(peer.bytesReceived, 0);
      },
    );

    test('a mismatch on one request never lets a later request through on the swapped certificate', () async {
      final peer = await tls(peerB);
      final c = client(peer.port, pin: peerA.identity.fingerprint);
      for (var i = 0; i < 4; i++) {
        expect(
          await errorOf(c.info()),
          isA<PeerFingerprintMismatchException>(),
          reason: 'attempt $i',
        );
      }
      expect(peer.requests, isEmpty);
      expect(peer.bytesReceived, 0);
    });

    // Guard: the secure context trusts nothing. A certificate that the PROCESS-WIDE default
    // context would trust must still go through the pin check (a client built on the default
    // context would skip badCertificateCallback for it).
    test('a certificate trusted by SecurityContext.defaultContext is still pin-checked', () async {
      try {
        SecurityContext.defaultContext.setTrustedCertificatesBytes(
          utf8.encode(peerB.identity.certPem),
        );
      } on Object {
        markTestSkipped('cannot load the self-signed certificate as a root');
        return;
      }
      final peer = await tls(peerB);
      final c = client(peer.port, pin: peerA.identity.fingerprint);
      expect(await errorOf(c.info()), isA<PeerFingerprintMismatchException>());
      expect(peer.bytesReceived, 0);
      // A first-contact client still learns the fingerprint of such a certificate.
      final first = client(peer.port);
      await first.info();
      expect(first.serverFingerprint, peerB.identity.fingerprint);
    });

    test(
      'a first-contact client refuses a different certificate later',
      () async {
        // Connection: close, so the next request needs a new TLS handshake.
        final peer = await RawTlsPeer.start(peerA, keepAlive: false);
        open.add(peer);
        final c = client(peer.port);
        await c.info();
        expect(c.serverFingerprint, peerA.identity.fingerprint);
        await peer.close();
        open.remove(peer);
        final swapped = await RawTlsPeer.start(peerB, port: peer.port);
        open.add(swapped);
        expect(
          await errorOf(c.info()),
          isA<PeerFingerprintMismatchException>(),
        );
        expect(swapped.bytesReceived, 0);
        expect(c.serverFingerprint, peerA.identity.fingerprint);
      },
    );
  });

  group('a transport failure is not an insecure peer', () {
    // [RED] Every TlsException is mapped to InsecurePeerException, including a connection that is
    // reset or closed during the handshake. The UI/CLI turns InsecurePeerException into "this
    // device is not secure: --allow-insecure?", so a flaky Wi-Fi reset would push the user to the
    // plaintext profile. A reset must stay a connection failure (SocketException, which
    // FileSender reports as NO_CONNECTION and which is retryable); only a peer that answers the
    // ClientHello with something that is not TLS (plain HTTP, a protocol/version alert) is
    // "insecure".
    for (final readFirst in [true, false]) {
      test('RED peer_reset_during_handshake_is_a_connection_failure_not_InsecurePeer '
          '(${readFirst ? 'after the ClientHello' : 'on accept'})', () async {
        final peer = await ResettingPeer.start(readFirst: readFirst);
        addTearDown(peer.close);
        final c = client(peer.port, pin: peerA.identity.fingerprint);
        final e = await errorOf(c.info());
        expect(e, isNotNull);
        expect(e, isNot(isA<InsecurePeerException>()));
        expect(e, isNot(isA<PeerFingerprintMismatchException>()));
        expect(e, isA<SocketException>());
      });
    }

    test('RED FileSender over a real ApiClient: a reset peer is FAILED(NO_CONNECTION), not an InsecurePeerException', () async {
      final peer = await ResettingPeer.start();
      addTearDown(peer.close);
      final tmp = Directory.systemTemp.createTempSync('p5r_reset');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final file = writeRandomFile(tmp, 'a.bin', 1024);
      final sender = FileSender(
        client: client(peer.port),
        self: infoFor('p5r-me', me.identity.fingerprint),
        security: sec,
        retryDelays: const [],
      );
      Object? thrown;
      SendResult? result;
      try {
        result = await sender.send([file]);
      } on Object catch (e) {
        thrown = e;
      }
      expect(thrown, isNull, reason: 'a transport failure is a SendResult');
      expect(result!.status, TransferStatus.failed);
      expect(result.failureReason, FailureReason.noConnection);
    });

    test(
      'control: a plain-HTTP peer is still an InsecurePeerException',
      () async {
        final peer = await RawPlainPeer.start();
        open.add(peer);
        final c = client(peer.port, pin: peerA.identity.fingerprint);
        expect(await errorOf(c.info()), isA<InsecurePeerException>());
        expect(peer.requests, isEmpty);
      },
    );
  });

  group('nothing secret is logged or thrown', () {
    test('a SAS first contact and a pin mismatch leave no key material in the logs', () async {
      final logs = LogCapture();
      addTearDown(logs.close);
      final tmp = Directory.systemTemp.createTempSync('p5r_log');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final file = writeRandomFile(tmp, 'a.bin', 1024);
      final receiverFp = peerA.identity.fingerprint;
      final fake = FakeSecurePeer(
        senderFp: me.identity.fingerprint,
        receiverFp: receiverFp,
      );
      final sender = FileSender(
        client: fake,
        self: infoFor('p5r-me', me.identity.fingerprint),
        security: sec,
        retryDelays: const [],
      );
      final result = await sender.send([file]);
      expect(result.isSuccess, isTrue);

      // Pin mismatch (fake presents peerA, the pin says peerB).
      final fake2 = FakeSecurePeer(
        senderFp: me.identity.fingerprint,
        receiverFp: receiverFp,
      );
      final pinned = FileSender(
        client: fake2,
        self: infoFor('p5r-me', me.identity.fingerprint),
        security: sec,
        pinnedReceiverFingerprint: peerB.identity.fingerprint,
        retryDelays: const [],
      );
      Object? err;
      try {
        await pinned.send([file]);
      } on Object catch (e) {
        err = e;
      }
      expect(err, isA<PeerFingerprintMismatchException>());

      final all =
          '${logs.text}\n$err\n'
          '${const InsecurePeerException()}\n${const SasAbortedException()}';
      expect(
        _hex64.hasMatch(all),
        isFalse,
        reason: 'full fingerprint in a log/exception',
      );
      expect(all, isNot(contains(b64urlEncode(fake.revealedNs!))));
      expect(all, isNot(contains(fake.request!.sasCommit!)));
      expect(all, isNot(contains(b64urlEncode(fake.nr))));
    });
  });

  group('the sender notices a receiver that changes the SAS exchange', () {
    for (final how in ['other-nr', 'no-sas', 'accepted-at-once']) {
      test(
        'reveal answered with $how: SasAbortedException, no code, no chunk',
        () async {
          final tmp = Directory.systemTemp.createTempSync('p5r_nr');
          addTearDown(() => tmp.deleteSync(recursive: true));
          final file = writeRandomFile(tmp, 'a.bin', 1024);
          final peer = _ShiftyReceiver(
            how,
            senderFp: me.identity.fingerprint,
            receiverFp: peerA.identity.fingerprint,
          );
          final events = <LsEvent>[];
          final sender = FileSender(
            client: peer,
            self: infoFor('p5r-me', me.identity.fingerprint),
            security: sec,
            retryDelays: const [],
            onEvent: events.add,
          );
          Object? error;
          try {
            await sender.send([file]);
          } on Object catch (e) {
            error = e;
          }
          expect(error, isA<SasAbortedException>());
          expect(events.whereType<SasReady>(), isEmpty);
          expect(peer.puts, 0);
          expect(
            peer.cancelled,
            isNotEmpty,
            reason: 'the receiver is told to drop the session',
          );
        },
      );
    }
  });

  group('a certificate the platform trusts normally is still pin-checked', () {
    // The identity certificates carry no subjectAltName, so dart:io's host-name check fails and
    // the callback runs even for a chain-valid certificate. A certificate WITH a matching
    // IP SAN that the default context trusts (as a CA-issued one would be) would skip
    // badCertificateCallback if the secure client were built on the default context.
    test('a default-context-trusted certificate with SAN IP:127.0.0.1 cannot bypass the pin', () async {
      if (!_opensslPresent()) {
        markTestSkipped('openssl is not installed');
        return;
      }
      final dir = Directory.systemTemp.createTempSync('p5r_ca');
      addTearDown(() => dir.deleteSync(recursive: true));
      final gen = Process.runSync('openssl', [
        'req',
        '-x509',
        '-newkey',
        'ec',
        '-pkeyopt',
        'ec_paramgen_curve:prime256v1',
        '-nodes',
        '-keyout',
        '${dir.path}/k.pem',
        '-out',
        '${dir.path}/c.pem',
        '-days',
        '2',
        '-subj',
        '/CN=localhost',
        '-addext',
        'subjectAltName=IP:127.0.0.1',
      ]);
      if (gen.exitCode != 0) {
        markTestSkipped('openssl could not create the certificate');
        return;
      }
      SecurityContext.defaultContext.setTrustedCertificates(
        '${dir.path}/c.pem',
      );
      final ctx = SecurityContext(withTrustedRoots: false)
        ..useCertificateChain('${dir.path}/c.pem')
        ..usePrivateKey('${dir.path}/k.pem');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        ctx,
      );
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((r) {
        requests++;
        r.response
          ..statusCode = 200
          ..close();
      });
      // Control: a plain dart:io client on the default context accepts it without a callback.
      final plain = HttpClient();
      addTearDown(() => plain.close(force: true));
      final ok = await (await plain.getUrl(
        Uri.parse('https://127.0.0.1:${server.port}/'),
      )).close();
      expect(
        ok.statusCode,
        200,
        reason: 'the harness: this certificate IS trusted by default',
      );
      final before = requests;

      final c = client(server.port, pin: peerA.identity.fingerprint);
      expect(await errorOf(c.info()), isA<PeerFingerprintMismatchException>());
      expect(
        requests,
        before,
        reason: 'a request reached a server whose key is not the pin',
      );
    });
  });
}
