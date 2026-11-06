// Inc 3 / P6a adversarial review tests (Card C5 / D3).
// Verifies core security invariants against seeded mutations:
//  1. Downgrade to plaintext peer refused with InsecurePeerException when allowInsecurePeers=false
//  2. Pinned fingerprint mismatch refused with PeerFingerprintMismatchException
//  3. Key change on known device id raises PeerKeyChanged
//  4. Engine enforces pinVerifier (PIN required/invalid refused)
//  5. Receive does not auto-accept first-contact transfer without SAS
//  6. Identity directory persistence across restarts keeps pinned contacts
//  7. Contacts-only visibility gates strangers
@TestOn('vm')
library;

import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/p6a_support.dart';

Future<void> main() async {
  final skip = await p6aSkipReason();
  late Directory sandbox;
  late P6aRig rig;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('ls_p6a_adv_');
    rig = P6aRig(sandbox);
  });

  tearDown(() async {
    for (final n in rig.nodes) {
      await n.dispose();
    }
    if (sandbox.existsSync()) {
      await sandbox.delete(recursive: true);
    }
  });

  File src(String name, int size, {int seed = 1}) {
    final f = File(p.join(sandbox.path, name));
    f.parent.createSync(recursive: true);
    final data = List.generate(size, (i) => (i + seed) & 0xff);
    f.writeAsBytesSync(data);
    return f;
  }

  group('P6a mutation 1: plaintext peer downgrade refusal', () {
    test('secure engine with allowInsecurePeers=false refuses plaintext peer with InsecurePeerException', () async {
      final a = await rig.start(
        'Alice',
        secure: true,
        allowInsecurePeers: false,
      );
      final b = await rig.start('Bob', secure: false); // Plaintext engine

      final f = src('secret.bin', 100);
      await expectLater(
        sendTo(a, b, [f]),
        throwsA(isA<InsecurePeerException>()),
        reason: 'secure engine must refuse downgrade to plaintext peer',
      );

      // Twin: when allowInsecurePeers=true, transfer succeeds
      final aAllowed = await rig.start(
        'AliceAllowed',
        secure: true,
        allowInsecurePeers: true,
      );
      final res = await sendTo(aAllowed, b, [f]);
      expect(
        res.isSuccess,
        isTrue,
        reason: 'allowInsecurePeers=true permits send',
      );
    }, skip: skip);
  });

  group(
    'P6a mutation 2 & 3: pinned fingerprint check and key-changed event',
    () {
      test('different key for known device id emits PeerKeyChanged and throws PeerFingerprintMismatchException', () async {
        final a = await rig.start('Alice');
        final b = await rig.start('Bob', ip: '127.0.0.30');

        // First send pins Bob
        final f = src('initial.bin', 100);
        final firstRes = await sendTo(a, b, [f]);
        expect(firstRes.isSuccess, isTrue);
        final oldFp = b.fp;

        // Bob restarts with same deviceId but new identity (new key)
        await rig.stop(b);
        final bNew = await rig.start(
          'BobNew',
          deviceId: b.deviceId,
          ip: '127.0.0.30',
        );
        expect(bNew.fp, isNot(equals(oldFp)));

        // Send to bNew must fail with PeerFingerprintMismatchException
        await expectLater(
          sendTo(a, bNew, [src('second.bin', 100)]),
          throwsA(isA<PeerFingerprintMismatchException>()),
        );

        // Must emit PeerKeyChanged event on Alice
        final changed = await a.events.next<PeerKeyChanged>(
          what: 'PeerKeyChanged on Alice',
        );
        expect(changed.deviceId, b.deviceId);
        expect(changed.pinnedFingerprint, oldFp);
        expect(changed.presentedFingerprint, bNew.fp);
      }, skip: skip);
    },
  );

  group('P6a mutation 4: pinVerifier wired through engine', () {
    const pin = '948201';
    const policy = PinPolicy(mode: PinMode.fixed);

    test('pinVerifier enforces PIN on incoming transfers', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob', pinPolicy: policy, pin: pin);

      expect(b.engine.pinGuard, isNotNull);
      expect(b.engine.pinGuard!.enforced, isTrue);

      // No PIN -> refused with pinRequired
      final none = await sendTo(a, b, [src('none.bin', 50)]);
      expect(none.status, TransferStatus.failed);
      expect(none.refusal, LsErrorCode.pinRequired);

      // Wrong PIN -> refused with pinInvalid
      final wrong = await sendTo(a, b, [src('wrong.bin', 50)], pin: '000000');
      expect(wrong.status, TransferStatus.failed);
      expect(wrong.refusal, LsErrorCode.pinInvalid);

      // Correct PIN -> succeeds
      final ok = await sendTo(a, b, [src('ok.bin', 50)], pin: pin);
      expect(ok.isSuccess, isTrue);
    }, skip: skip);
  });

  group('P6a mutation 8: first contact not auto-accepted without SAS', () {
    test(
      'autoAccept=true on receiver does not skip SAS on first contact',
      () async {
        final a = await rig.start('Alice');
        // Bob has autoAccept=true, but acceptSas=false (user has not compared/accepted SAS yet)
        final b = await rig.start('Bob', autoAccept: true, acceptSas: false);

        final send = a.engine.beginSendFiles(
          [src('first.bin', 100)],
          host: b.ip,
          port: b.port,
        );
        final readyB = await b.events.next<SasReady>(what: 'SasReady on Bob');

        final info = b.engine.incomingInfo(readyB.sessionId);
        expect(info, isNotNull);
        expect(
          info!.sasRequired,
          isTrue,
          reason: 'first contact must require SAS',
        );

        // Session must still be pending, not yet in progress
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(contactsOf(a), isEmpty);
        expect(contactsOf(b), isEmpty);

        // When Bob accepts the SAS, transfer completes and both pin
        await b.engine.receiver.accept(readyB.sessionId);
        final res = await send.result;
        expect(res.isSuccess, isTrue);
        expect(contactsOf(a)[b.deviceId], isNotNull);
        expect(contactsOf(b)[a.deviceId], isNotNull);
      },
      skip: skip,
    );
  });

  group('P6a mutation 9: identity and contacts persistence', () {
    test(
      'restarting engine with same identity dir preserves pinned contacts',
      () async {
        final idDir = Directory(p.join(sandbox.path, 'shared-id-alice'));
        final a1 = await rig.start('Alice1', idDir: idDir);
        final b = await rig.start('Bob');

        // Pin Bob on Alice
        final res1 = await sendTo(a1, b, [src('f1.bin', 100)]);
        expect(res1.isSuccess, isTrue);
        expect(
          a1.engine.currentContacts.any((c) => c.deviceId == b.deviceId),
          isTrue,
        );

        // Restart Alice using same idDir
        await rig.stop(a1);
        final a2 = await rig.start(
          'Alice2',
          idDir: idDir,
          deviceId: a1.deviceId,
        );

        // Alice2 still has Bob in contacts
        expect(
          a2.engine.currentContacts.any((c) => c.deviceId == b.deviceId),
          isTrue,
        );

        // Second send needs NO SAS
        final res2 = await sendTo(a2, b, [src('f2.bin', 100)]);
        expect(res2.isSuccess, isTrue);
        expect(
          a2.sasCodes(outgoing: true),
          isEmpty,
          reason: 'pinned contact requires no SAS',
        );
      },
      skip: skip,
    );
  });

  group('P6a mutation 10: contacts-only visibility gates strangers', () {
    test('stranger cannot transfer to a Contacts-only receiver', () async {
      final stranger = await rig.start('Stranger');
      final b = await rig.start('Bob', mode: const ReceiveAlways());
      // Bob switches to Contacts-only visibility
      await b.engine.receive.setVisibility(ReceiveVisibility.contacts);

      // Stranger send to Bob fails
      final res = await sendTo(stranger, b, [src('stranger.bin', 100)]);
      expect(
        res.isSuccess,
        isFalse,
        reason: 'stranger must be refused by Contacts-only receiver',
      );

      // Now add Friend as a known contact on Bob, and Bob on Friend
      final friend = await rig.start('Friend');
      await b.engine.addContact(
        deviceId: friend.deviceId,
        fingerprint: friend.fp,
        alias: 'Friend',
      );
      await friend.engine.addContact(
        deviceId: b.deviceId,
        fingerprint: b.fp,
        alias: 'Bob',
      );

      // Friend send to Bob succeeds
      final friendRes = await sendTo(friend, b, [src('friend.bin', 100)]);
      expect(
        friendRes.isSuccess,
        isTrue,
        reason: 'known contact can send to Contacts-only receiver',
      );
    }, skip: skip);
  });
}
