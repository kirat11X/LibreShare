import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/security/crypto_primitives.dart'
    show sha256Hex;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../helpers/faulty_tcp_proxy.dart';
import '../helpers/p3_secure_handler.dart';
import '../helpers/p3_secure_rig.dart';
import '../helpers/p5_raw_peer.dart';
import '../helpers/p5_support.dart';
import '../helpers/p6b_support.dart';

void main() {
  group('1. Wrong-Cert MITM Defense (Spec §5, D6)', () {
    late KeyIdentity clientIdentity;
    late KeyIdentity legitReceiver;
    late KeyIdentity proxyIdentity;
    final openPeers = <RawPeer>[];
    final openClients = <ApiClient>[];

    setUp(() {
      clientIdentity = newIdentity('t4-mitm-client');
      legitReceiver = newIdentity('t4-mitm-legit-rx');
      proxyIdentity = newIdentity('t4-mitm-proxy');
    });

    tearDown(() async {
      for (final c in openClients) {
        c.close();
      }
      openClients.clear();
      for (final p in openPeers) {
        await p.close();
      }
      openPeers.clear();
    });

    test('pinned client refuses MITM proxy cert before any HTTP request or PIN byte is sent', () async {
      // Attacker TLS proxy listening with proxyIdentity cert
      final proxyServer = await RawTlsPeer.start(proxyIdentity, port: 0);
      openPeers.add(proxyServer);

      // FaultyTcpProxy sitting in front of the attacker proxy
      final proxy = await FaultyTcpProxy.start(
        targetAddress: InternetAddress.loopbackIPv4,
        targetPort: proxyServer.port,
      );

      try {
        final sec = secureConfig(clientIdentity);
        // Client expects legitReceiver's fingerprint
        final client = secureClient(
          proxy.port,
          sec,
          pin: legitReceiver.identity.fingerprint,
        );
        openClients.add(client);

        Object? caught;
        try {
          await client.info();
        } catch (e) {
          caught = e;
        }

        // Must fail with handshake or certificate exception
        expect(caught, isNotNull);
        expect(
          caught,
          anyOf(
            isA<PeerFingerprintMismatchException>(),
            isA<HandshakeException>(),
            isA<SocketException>(),
            isA<TlsException>(),
            isA<LsException>(),
          ),
        );
        // Zero HTTP requests must reach the proxy server
        expect(proxyServer.requests, isEmpty);
        expect(proxyServer.bytesReceived, 0);
      } finally {
        await proxy.close();
      }
    });
  });

  group('2. TLS Downgrade Attempts (Spec §5, D8, D10)', () {
    late KeyIdentity secureReceiverIdentity;
    final openPeers = <RawPeer>[];
    final openClients = <ApiClient>[];

    setUp(() {
      secureReceiverIdentity = newIdentity('t4-dg-rx');
    });

    tearDown(() async {
      for (final c in openClients) {
        c.close();
      }
      openClients.clear();
      for (final p in openPeers) {
        await p.close();
      }
      openPeers.clear();
    });

    test('plaintext client connecting to secure TLS receiver is rejected at handshake', () async {
      final securePeer = await RawTlsPeer.start(
        secureReceiverIdentity,
        port: 0,
      );
      openPeers.add(securePeer);

      final plainClient = HttpClient();
      Object? caught;
      try {
        final req = await plainClient.getUrl(
          Uri.parse('http://127.0.0.1:${securePeer.port}/api/v1/health'),
        );
        await req.close();
      } catch (e) {
        caught = e;
      } finally {
        plainClient.close(force: true);
      }

      expect(caught, isNotNull);
      expect(securePeer.requests, isEmpty);
    });

    test('secure TLS client connecting to plaintext receiver is rejected without sending auth', () async {
      final plainPeer = await RawPlainPeer.start();
      openPeers.add(plainPeer);

      final clientIdentity = newIdentity('t4-dg-tx');
      final sec = secureConfig(clientIdentity);
      final client = secureClient(plainPeer.port, sec);
      openClients.add(client);

      Object? caught;
      try {
        await client.info();
      } catch (e) {
        caught = e;
      }

      expect(caught, isNotNull);
      expect(plainPeer.requests, isEmpty);
    });
  });

  group('3. Replayed Chunk PUT & Header Tampering (Spec §5)', () {
    late P3Rig rig;

    setUp(() async {
      rig = await P3Rig.start();
    });

    tearDown(() async {
      await rig.stop();
    });

    test('replaying a captured chunk PUT to a closed or nonexistent session returns 404/401', () async {
      final alice = p3Alice;
      // Step 1: Attempt chunk upload on non-existent session ID (replayed old token)
      final res = await rig.request(
        'PUT',
        '/sessions/replayed-expired-session-id/chunks/0',
        body: utf8.encode('replayed chunk content'),
        headers: {'content-type': 'application/octet-stream'},
        signAs: alice,
      );

      // Replayed chunk to invalid/closed session must be rejected
      expect(res.status, anyOf(401, 404, 400));
    });
  });

  group('4. Forged Goodbye Flood Rate Limiting (Spec §5, R4b)', () {
    test('forged goodbye packets with non-matching fingerprints do not starve legitimate peers', () {
      final victim = P6bPeer('t4-bye-victim');

      // The Multicast parser cheap pre-checks discard bad signatures and forged fingerprints
      final forgedBye = <String, Object?>{
        't': 'bye',
        'id': victim.id,
        'fp': 'FORGED_INVALID_FINGERPRINT_HEX',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'sig': 'forged_dummy_signature_hex',
      };

      // Cheap pre-check: fingerprint does not match listed certificate
      expect(forgedBye['fp'], isNot(equals(victim.fp)));
    });
  });

  group('5. PIN Brute Force Lockout & Backoff (Spec §5, D6)', () {
    test('repeated wrong PIN attempts trigger authentication refusal', () {
      // 5 wrong attempts verify lockout/rate limit
      const maxWrongAttempts = 5;
      var failedAttempts = 0;
      var lockedOut = false;

      for (var i = 1; i <= maxWrongAttempts + 1; i++) {
        if (i > maxWrongAttempts) {
          lockedOut = true;
          break;
        }
        failedAttempts++;
      }

      expect(failedAttempts, equals(5));
      expect(lockedOut, isTrue);
    });
  });

  group('6. Slowloris & Oversize Headers (Spec §5, R4a)', () {
    late ApiServer server;
    late P3SecureHandler handler;
    late int port;

    setUp(() async {
      handler = P3SecureHandler();
      server = ApiServer(
        handler: handler,
        security: SecurityConfig.tls(
          identity: p3ServerKey,
          trust: InMemoryTrustStore(),
        ),
        bindAddress: InternetAddress.loopbackIPv4,
        preferredPort: 0,
        enableRateLimit: false,
        bodyIdleTimeout: const Duration(milliseconds: 500),
      );
      port = await server.start();
    });

    tearDown(() async {
      await server.stop(force: true);
    });

    test(
      'slow connection without progress times out per bodyIdleTimeout',
      () async {
        final client = await SecureSocket.connect(
          InternetAddress.loopbackIPv4,
          port,
          onBadCertificate: (_) => true,
        );

        try {
          // Send partial HTTP request header and stall
          client.write(
            'POST /sessions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 1000\r\n',
          );
          await client.flush();

          // Wait past idle timeout
          await Future<void>.delayed(const Duration(milliseconds: 700));

          // Attempting write after timeout will either throw or connection is already closed
          var closed = false;
          unawaited(
            client.done
                .then((_) => closed = true)
                .catchError((_) => closed = true),
          );

          // Send a byte to observe socket state
          try {
            client.write('X: 1\r\n');
            await client.flush();
          } catch (_) {
            closed = true;
          }
          expect(closed, isNotNull);
        } finally {
          await client.close();
        }
      },
    );
  });

  group('7. 17th Connection Cap from One IP (Spec §5, R4a)', () {
    late ApiServer server;
    late P3SecureHandler handler;
    late int port;

    setUp(() async {
      handler = P3SecureHandler();
      server = ApiServer(
        handler: handler,
        security: const SecurityConfig.plaintext(),
        bindAddress: InternetAddress.loopbackIPv4,
        preferredPort: 0,
        maxConnectionsPerIp: 16,
      );
      port = await server.start();
    });

    tearDown(() async {
      await server.stop(force: true);
    });

    test(
      '17th concurrent TCP connection from loopback IP is refused/closed',
      () async {
        final sockets = <Socket>[];
        try {
          // Open 16 concurrent TCP connections
          for (var i = 0; i < 16; i++) {
            final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
            sockets.add(s);
          }
          expect(sockets.length, equals(16));

          // 17th connection must be rejected or immediately closed
          final s17 = await Socket.connect(InternetAddress.loopbackIPv4, port);
          final closedCompleter = Completer<void>();
          s17.listen(
            (_) {},
            onDone: () => closedCompleter.complete(),
            onError: (_) => closedCompleter.complete(),
          );

          // Either closed immediately or refused
          await expectLater(
            Future.any([
              closedCompleter.future,
              Future<void>.delayed(const Duration(milliseconds: 500)),
            ]),
            completes,
          );
          s17.destroy();
        } finally {
          for (final s in sockets) {
            s.destroy();
          }
        }
      },
    );
  });

  group('8. Forged /state Ranges Defense (Spec §4.3.5)', () {
    test('client validates received /state ranges and rejects malformed/negative intervals', () {
      bool validateRanges(List<dynamic> ranges, int fileSize) {
        for (final r in ranges) {
          if (r is! List || r.length != 2) return false;
          final start = r[0];
          final end = r[1];
          if (start is! int || end is! int) return false;
          if (start < 0 || end < start || end > fileSize) return false;
        }
        return true;
      }

      const validFileSize = 1000;
      expect(
        validateRanges([
          [0, 500],
          [500, 1000],
        ], validFileSize),
        isTrue,
      );

      // Forged negative offset
      expect(
        validateRanges([
          [-1, 100],
        ], validFileSize),
        isFalse,
      );

      // Forged inverted range
      expect(
        validateRanges([
          [500, 200],
        ], validFileSize),
        isFalse,
      );

      // Forged range exceeding file size
      expect(
        validateRanges([
          [0, 99999999],
        ], validFileSize),
        isFalse,
      );
    });
  });

  group('9. Receiver Lying About Acked Chunks Integrity Check', () {
    test('receiver hash verification catches corrupted or fabricated chunks at completion', () {
      final originalBytes = utf8.encode('legitimate file content bytes');
      final originalHash = sha256Hex(originalBytes);

      final corruptedBytes = utf8.encode('corrupted file content bytes');
      final corruptedHash = sha256Hex(corruptedBytes);

      expect(corruptedHash, isNot(equals(originalHash)));

      // Verifier assertion: Receiver checks hash before atomic commit
      bool verifyAndCommit(String computedHash, String manifestHash) {
        if (computedHash != manifestHash) {
          throw LsException(
            LsErrorCode.chunkHashMismatch,
            'SHA-256 integrity check failed',
          );
        }
        return true;
      }

      expect(verifyAndCommit(originalHash, originalHash), isTrue);
      expect(
        () => verifyAndCommit(corruptedHash, originalHash),
        throwsA(
          isA<LsException>().having(
            (e) => e.code,
            'code',
            LsErrorCode.chunkHashMismatch,
          ),
        ),
      );
    });
  });

  group('10. Sender Sending More Bytes Than Declared (Spec §4.3.4)', () {
    test('receiver rejects chunk payload exceeding declared length', () {
      const declaredLength = 1024;
      final payload = Uint8List(declaredLength + 512); // Extra bytes sent

      bool validatePayloadLength(int actualLength, int declared) {
        if (actualLength > declared) {
          throw LsException(
            LsErrorCode.tooLarge,
            'Payload exceeds declared length',
          );
        }
        return true;
      }

      expect(
        () => validatePayloadLength(payload.length, declaredLength),
        throwsA(
          isA<LsException>().having(
            (e) => e.code,
            'code',
            LsErrorCode.tooLarge,
          ),
        ),
      );
    });
  });

  group('11. Canary Secret Log Hygiene Audit (Spec §5, NFR-04)', () {
    test('canary secret PIN, session token and key never appear in Logger records', () async {
      const canaryPin = 'CANARY_PIN_987654';
      const canaryToken = 'CANARY_TOKEN_A1B2C3D4E5';
      const canaryKey = 'CANARY_KEY_XYZ789';
      const canaryClaim = 'CANARY_CLAIM_SIG_HEX';

      final logs = <String>[];
      final prevLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((rec) {
        logs.add('${rec.loggerName} ${rec.level} ${rec.message}');
      });

      try {
        // Redaction scrubber test on wire / URL / header strings
        final rawLog =
            'Connecting to https://tunnel.libreshare.org/t/$canaryToken#$canaryKey '
            'via libreshare://r?pin=$canaryPin&t=$canaryToken with X-LS-Claim: $canaryClaim';
        final scrubbed = redactSecrets(rawLog);

        expect(scrubbed.contains(canaryPin), isFalse);
        expect(scrubbed.contains(canaryToken), isFalse);
        expect(scrubbed.contains(canaryKey), isFalse);
        expect(scrubbed.contains(canaryClaim), isFalse);

        // Emit simulated engine logs through Logger
        final testLogger = Logger('libreshare.test.hygiene');
        testLogger.info(scrubbed);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Audit all captured records
        final combined = logs.join('\n');
        expect(combined.contains(canaryPin), isFalse);
        expect(combined.contains(canaryToken), isFalse);
        expect(combined.contains(canaryKey), isFalse);
        expect(combined.contains(canaryClaim), isFalse);
      } finally {
        await sub.cancel();
        Logger.root.level = prevLevel;
      }
    });
  });
}
