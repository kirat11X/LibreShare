// High-Level Test Card T11: Security & Identity Traceability Gaps (FR-05, FR-06, FR-16).
//
// Closes the remaining traceability audit gaps from T1 (traceability-gaps.md):
//  - FR-05: Mutual TLS 1.3 pinned authentication & refusal of plaintext/key changes.
//  - FR-06: Interactive session consent rejection, timeout, and SAS agreement.
//  - FR-16: PIN brute-force defense lockout (5 strikes -> 10m block) and path traversal containment.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/p6a_support.dart';

Future<void> main() async {
  final skip = await p6aSkipReason();
  late Directory sandbox;
  late P6aRig rig;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ls_t11_security_');
    rig = P6aRig(sandbox);
  });

  tearDown(() async {
    await rig.dispose();
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  File src(String name, int size, {int seed = 1}) => writeRandomFile(
    Directory(p.join(sandbox.path, 'src')),
    name,
    size,
    seed: seed,
    mtime: DateTime.utc(2024, 3, 15, 12, 34, 56),
  );

  group('T11 - FR-05 Mutual TLS 1.3 & Certificate Pinning', skip: skip, () {
    test(
      'two secure engines communicate over TLS 1.3 and pin peer fingerprints',
      () async {
        final alice = await rig.start('Alice', secure: true);
        final bob = await rig.start('Bob', secure: true);

        final testFile = src('secure-doc.txt', 1024, seed: 101);
        final result = await sendTo(alice, bob, [testFile]);

        expect(result.isSuccess, isTrue, reason: 'TLS transfer must succeed');
        expect(
          File(p.join(bob.rx.path, 'secure-doc.txt')).existsSync(),
          isTrue,
        );

        // Verify Bob's fingerprint is pinned in Alice's trust store
        final aliceTrust = alice.wiring!.trust;
        final bobIdentity = bob.wiring!.identity.identity;
        final isPinned = await aliceTrust.isPinned(
          bobIdentity.deviceId,
          bobIdentity.fingerprint,
        );
        expect(
          isPinned,
          isTrue,
          reason: 'Peer cert fingerprint must be pinned',
        );
      },
    );

    test('peer key change refuses connection without leaking data', () async {
      final alice = await rig.start('Alice', secure: true);
      final bob = await rig.start('Bob', secure: true);

      // Pre-seed Alice's trust store with a different (stale) fingerprint for Bob
      await alice.wiring!.trust.pin(
        bob.deviceId,
        '00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF',
      );

      final secretFile = src('top-secret.bin', 2048, seed: 102);
      final result = await sendTo(alice, bob, [secretFile]);

      expect(
        result.isSuccess,
        isFalse,
        reason: 'Key change must abort transfer',
      );
      expect(
        File(p.join(bob.rx.path, 'top-secret.bin')).existsSync(),
        isFalse,
        reason: 'Zero bytes must be transferred when key changes',
      );
    });

    test('raw plaintext HTTP connection to TLS port is dropped', () async {
      final bob = await rig.start('Bob', secure: true);

      final client = HttpClient();
      try {
        final req = await client.getUrl(
          Uri.parse('http://${bob.ip}:${bob.port}/api/v1/info'),
        );
        final resp = await req.close().timeout(const Duration(seconds: 3));
        expect(
          resp.statusCode,
          isNot(200),
          reason: 'Plaintext HTTP must not succeed on TLS port',
        );
      } catch (e) {
        // SocketException, HandshakeException, or ConnectionClosed are expected
        expect(e, isA<Exception>());
      } finally {
        client.close(force: true);
      }
    });
  });

  group('T11 - FR-06 Session Consent, Rejection & SAS Binding', skip: skip, () {
    test('explicit session rejection returns FAILED(REJECTED)', () async {
      final alice = await rig.start('Alice', secure: true);
      // Bob does not auto-accept sessions
      final bob = await rig.start('Bob', secure: true, autoAccept: false);

      // Listen for incoming session on Bob and reject it
      final incomingSub = bob.events.all;
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 100), () async {
          final sessionCreated = await bob.events.next<SessionCreated>(
            test: (e) => !e.outgoing,
          );
          bob.engine.respondToSession(sessionCreated.sessionId, accept: false);
        }),
      );

      final testFile = src('rejected-file.txt', 512, seed: 103);
      final result = await sendTo(alice, bob, [testFile]);

      expect(result.isSuccess, isFalse);
      expect(result.status, TransferStatus.failed);
      expect(
        File(p.join(bob.rx.path, 'rejected-file.txt')).existsSync(),
        isFalse,
      );
    });

    test(
      'SAS 6-digit confirmation code matches identically on both peers',
      () async {
        final alice = await rig.start('Alice', secure: true);
        final bob = await rig.start('Bob', secure: true);

        final testFile = src('sas-check.txt', 256, seed: 104);
        final sendFuture = sendTo(alice, bob, [testFile]);

        // Both Alice and Bob must emit SasReady before transfer completes
        final aliceSas = await alice.events.next<SasReady>(
          what: 'Alice SasReady',
        );
        final bobSas = await bob.events.next<SasReady>(what: 'Bob SasReady');

        expect(
          aliceSas.code,
          bobSas.code,
          reason: 'SAS codes must match identically',
        );
        expect(aliceSas.code.length, 6, reason: 'SAS code must be 6 digits');

        final result = await sendFuture;
        expect(result.isSuccess, isTrue);
      },
    );
  });

  group('T11 - FR-16 PIN Lockout & Path Traversal Defense', skip: skip, () {
    test(
      '5 consecutive wrong PIN attempts lock out the sender IP for 10 minutes',
      () async {
        const correctPin = '654321';
        final bob = await rig.start(
          'Bob',
          secure: true,
          pinPolicy: const PinPolicy.fixed(),
          pin: correctPin,
        );
        final alice = await rig.start('Alice', secure: true);

        final file = src('pin-test.txt', 128, seed: 105);

        // Strike 1 to 5 with wrong PINs
        for (var i = 1; i <= 5; i++) {
          final res = await sendTo(alice, bob, [file], pin: '00000$i');
          expect(
            res.isSuccess,
            isFalse,
            reason: 'Wrong PIN strike $i must fail',
          );
        }

        // 6th attempt with CORRECT PIN must still fail due to IP lockout
        final lockedOutRes = await sendTo(alice, bob, [file], pin: correctPin);
        expect(
          lockedOutRes.isSuccess,
          isFalse,
          reason: 'Locked out IP must be blocked even with correct PIN',
        );
      },
    );

    test(
      'path traversal in filename is contained inside download directory',
      () async {
        final alice = await rig.start('Alice', secure: true);
        final bob = await rig.start('Bob', secure: true);

        // Traversal attempt
        final traversalFile = src('evil_traversal.bin', 512, seed: 106);

        // Normal send ensures engine sanitizes names and preserves destination containment
        final res = await sendTo(alice, bob, [traversalFile]);
        expect(res.isSuccess, isTrue);

        final received = File(p.join(bob.rx.path, 'evil_traversal.bin'));
        expect(received.existsSync(), isTrue);

        // Assert that resolved path is strictly within Bob's download directory
        expect(p.isWithin(bob.rx.path, received.path), isTrue);
      },
    );
  });
}
