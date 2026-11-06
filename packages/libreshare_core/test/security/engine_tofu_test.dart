// P6a - trust on first use through the engine facade: SAS on both sides at first contact, the pin
// afterwards, no SAS the second time, a changed key refused, explicit removal then SAS again.
//
// Spec: LSP-1 5.1 (commit/reveal SAS, receiver never auto-accepts a commitment, "Trust this device"
// pins), 4.7 / 5 (a pin mismatch is never overridden by a SAS), docs/plans/inc3-seams.md data flow 5
// (receiver pins the sender as `known` when the user accepts a SAS-confirmed session; the sender pins
// the receiver when its session reaches IN_PROGRESS after a SAS flow; SendResult.receiverFingerprint),
// docs/plans/inc3.md section 4.1 `security/key_change_test` and `sas_binding_test`.
//
// SPEC-GAP: when the receiver of a send has a different key than the one pinned for its device id,
// the engine throws PeerFingerprintMismatchException (the P5 type) and also emits a PeerKeyChanged
// event (pinned fingerprint = the old one, presented = the new one) on the sending engine. The
// sender never pins anything in that case.
// SPEC-GAP: a send that the receiver refuses with KEY_CHANGED / BLOCKED comes back as a failed
// SendResult (FileSender maps those codes to PROTOCOL_ERROR / REJECTED), not as an exception.
@TestOn('vm')
library;

import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/p6a_support.dart';

final RegExp sixDigits = RegExp(r'^\d{6}$');

Future<void> main() async {
  final skip = await p6aSkipReason();
  late Directory sandbox;
  late P6aRig rig;
  var counter = 0;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ls_p6a_tofu_');
    rig = P6aRig(sandbox);
  });
  tearDown(() async {
    await rig.dispose();
    sandbox.deleteSync(recursive: true);
  });

  File src(String name, int size, {int seed = 1}) => writeRandomFile(
    Directory(p.join(sandbox.path, 'src')),
    '${counter++}-$name',
    size,
    seed: seed,
  );

  int incomingSessions(P6aNode n) =>
      n.events.of<SessionCreated>().where((e) => !e.outgoing).length;

  // LSP-1 5.1 and seams data flow 4/5.
  group('first contact', () {
    test('SAS is shown on both sides with equal codes; both ends pin the other as known', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob');
      final f = src('hello.bin', 1234);

      final res = await sendTo(a, b, [f]);

      expect(res.isSuccess, isTrue, reason: '$res');
      expect(
        res.receiverFingerprint,
        b.fp,
        reason: 'the fingerprint the sender saw',
      );
      final codeA = a.sasCodes(outgoing: true);
      final codeB = b.sasCodes(outgoing: false);
      expect(codeA, hasLength(1));
      expect(codeB, hasLength(1));
      expect(codeA.single, matches(sixDigits));
      expect(
        codeA.single,
        codeB.single,
        reason: 'both users compare the same code',
      );
      expect(
        a.sasCodes(outgoing: false),
        isEmpty,
        reason: 'the sender never shows an incoming code',
      );
      expect(b.sasCodes(outgoing: true), isEmpty);
      // The same code is tied to the same session id on the receiver.
      final readyB = b.events.of<SasReady>().single;
      final createdB = b.events.of<SessionCreated>().single;
      expect(readyB.sessionId, createdB.sessionId);

      // Pins on both sides.
      final ca = contactsOf(a)[b.deviceId];
      expect(
        ca,
        isNotNull,
        reason: 'the sender pins the receiver after the SAS-confirmed session',
      );
      expect(ca!.fingerprint, b.fp);
      expect(ca.alias, 'Bob');
      expect(ca.trust, PeerTrust.known);
      final cb = contactsOf(b)[a.deviceId];
      expect(
        cb,
        isNotNull,
        reason: 'the receiver pins the sender when its user accepted',
      );
      expect(cb!.fingerprint, a.fp);
      expect(cb.alias, 'Alice');
      expect(cb.trust, PeerTrust.known);
      expect(
        b.events.of<ContactChanged>().map((e) => e.deviceId),
        contains(a.deviceId),
      );

      await expectSameFile(f, File(p.join(b.rx.path, p.basename(f.path))));
    }, skip: skip);

    test('a second SAS flow with another pair shows another code (the code is not a constant)', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob');
      final c = await rig.start('Carol');
      expect((await sendTo(a, b, [src('x.bin', 10)])).isSuccess, isTrue);
      expect((await sendTo(a, c, [src('y.bin', 10)])).isSuccess, isTrue);
      expect(a.sasCodes(outgoing: true), hasLength(2));
      expect(
        a.sasCodes(outgoing: true)[0],
        isNot(a.sasCodes(outgoing: true)[1]),
      );
      expect(c.sasCodes(outgoing: false).single, a.sasCodes(outgoing: true)[1]);
    }, skip: skip);

    test(
      'the second send to the same device needs no SAS and still arrives',
      () async {
        final a = await rig.start('Alice');
        final b = await rig.start('Bob');
        expect((await sendTo(a, b, [src('first.bin', 100)])).isSuccess, isTrue);
        final sasA = a.sasCodes(outgoing: true).length;
        final sasB = b.sasCodes(outgoing: false).length;
        expect([sasA, sasB], [1, 1]);

        final f2 = src('second.bin', 4321, seed: 9);
        final res = await sendTo(a, b, [f2]);
        expect(res.isSuccess, isTrue, reason: '$res');
        expect(
          a.sasCodes(outgoing: true),
          hasLength(sasA),
          reason: 'no new SAS on the sender',
        );
        expect(
          b.sasCodes(outgoing: false),
          hasLength(sasB),
          reason: 'no new SAS on the receiver',
        );
        expect(res.receiverFingerprint, b.fp);
        await expectSameFile(f2, File(p.join(b.rx.path, p.basename(f2.path))));
      },
      skip: skip,
    );

    test('the reverse direction after first contact needs no SAS either (both sides pinned)', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob');
      expect((await sendTo(a, b, [src('go.bin', 100)])).isSuccess, isTrue);
      final res = await sendTo(b, a, [src('back.bin', 100)]);
      expect(res.isSuccess, isTrue, reason: '$res');
      expect(b.sasCodes(outgoing: true), isEmpty);
      expect(a.sasCodes(outgoing: false), isEmpty);
    }, skip: skip);

    test('engine autoAccept does not skip the SAS comparison: the session waits for the user', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob', autoAccept: true, acceptSas: false);
      final f = src('wait.bin', 500);

      final send = a.engine.beginSendFiles([f], host: b.ip, port: b.port);
      final readyB = await b.events.next<SasReady>(test: (e) => !e.outgoing);
      final readyA = await a.events.next<SasReady>(test: (e) => e.outgoing);
      expect(readyA.code, readyB.code);

      await settle(300);
      expect(
        send.isFinished,
        isFalse,
        reason: 'nothing may flow before somebody pressed Accept',
      );
      expect(b.engine.receiver.pendingSessionIds, [readyB.sessionId]);
      expect(b.rx.existsSync() ? b.rx.listSync() : const [], isEmpty);
      final info = b.engine.incomingInfo(readyB.sessionId)!;
      expect(info.sasRequired, isTrue);
      expect(info.sasCode, readyB.code);
      expect(info.peer!.fingerprint, a.fp);
      expect(info.trust, PeerTrust.unknown);
      expect(info.keyChanged, isFalse);
      expect(
        contactsOf(a),
        isEmpty,
        reason: 'not pinned before the receiver accepted',
      );
      expect(contactsOf(b), isEmpty);

      await b.engine.receiver.accept(readyB.sessionId);
      final res = await send.result;
      expect(res.isSuccess, isTrue, reason: '$res');
      await expectSameFile(f, File(p.join(b.rx.path, p.basename(f.path))));
      expect(contactsOf(a)[b.deviceId], isNotNull);
    }, skip: skip);

    test('incomingInfo of a pinned sender: no SAS required, trust known; unknown session -> null', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob', autoAccept: false, acceptSas: false);
      // Pin both ways first.
      await a.engine.addContact(
        deviceId: b.deviceId,
        fingerprint: b.fp,
        alias: 'Bob',
      );
      await b.engine.addContact(
        deviceId: a.deviceId,
        fingerprint: a.fp,
        alias: 'Alice',
      );
      final send = a.engine.beginSendFiles(
        [src('p.bin', 10)],
        host: b.ip,
        port: b.port,
      );
      final created = await b.events.next<SessionCreated>(
        test: (e) => !e.outgoing,
      );
      final info = b.engine.incomingInfo(created.sessionId)!;
      expect(info.sasRequired, isFalse);
      expect(info.sasCode, isNull);
      expect(info.trust, PeerTrust.known);
      expect(info.peer!.fingerprint, a.fp);
      expect(b.engine.incomingInfo('does-not-exist'), isNull);
      await b.engine.receiver.reject(created.sessionId);
      expect((await send.result).failureReason, FailureReason.rejected);
    }, skip: skip);
  });

  group('refused or aborted first contact pins nobody', () {
    test('the receiver rejects after the SAS: FAILED(REJECTED), nothing pinned, nothing received', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob', acceptSas: false);
      final send = a.engine.beginSendFiles(
        [src('no.bin', 100)],
        host: b.ip,
        port: b.port,
      );
      final ready = await b.events.next<SasReady>(test: (e) => !e.outgoing);
      await b.engine.receiver.reject(ready.sessionId);

      final res = await send.result;
      expect(res.status, TransferStatus.failed);
      expect(res.failureReason, FailureReason.rejected);
      expect(
        res.refusal,
        isNull,
        reason: 'the receiver user said no: a status, not a wire error',
      );
      expect(
        res.receiverFingerprint,
        isNull,
        reason: 'a rejecting receiver is never pinned',
      );
      expect(contactsOf(a), isEmpty);
      expect(contactsOf(b), isEmpty);
      expect(b.rx.existsSync() ? b.rx.listSync() : const [], isEmpty);
      expect(b.events.of<FileSaved>(), isEmpty);
    }, skip: skip);

    test('the sender cancels while comparing the codes: SasAbortedException, nothing pinned, receiver session failed', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob', acceptSas: false);
      final send = a.engine.beginSendFiles(
        [src('abort.bin', 100)],
        host: b.ip,
        port: b.port,
      );
      await a.events.next<SasReady>(test: (e) => e.outgoing);
      await send.cancel();

      await expectLater(send.result, throwsA(isA<SasAbortedException>()));
      expect(contactsOf(a), isEmpty);
      expect(contactsOf(b), isEmpty);
      await b.events.next<SessionFinished>(
        test: (e) => !e.success,
        what: 'receiver learns that the session was cancelled',
      );
      expect(b.rx.existsSync() ? b.rx.listSync() : const [], isEmpty);
    }, skip: skip);
  });

  // docs/plans/inc3.md section 4.1 key_change_test.
  group('a changed key is refused', () {
    test('receiver with a new key and the same device id: PeerFingerprintMismatch + PeerKeyChanged, nothing sent, pin kept', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob', ip: '127.0.0.50');
      expect(
        (await sendTo(a, b, [src('ok.bin', 100)])).isSuccess,
        isTrue,
        reason: 'twin: the same send works before the key changed',
      );
      final oldFp = b.fp;
      await rig.stop(b);

      final b2 = await rig.start(
        'Bob',
        deviceId: b.deviceId,
        ip: '127.0.0.50',
        idDir: Directory(p.join(sandbox.path, 'id-bob-new')),
      );
      expect(b2.deviceId, b.deviceId);
      expect(b2.fp, isNot(oldFp));

      await expectLater(
        sendTo(a, b2, [src('secret.bin', 5000)]),
        throwsA(isA<PeerFingerprintMismatchException>()),
      );
      final changed = await a.events.next<PeerKeyChanged>(
        what: 'PeerKeyChanged on the sender',
      );
      expect(changed.deviceId, b.deviceId);
      expect(changed.pinnedFingerprint, oldFp);
      expect(changed.presentedFingerprint, b2.fp);

      expect(
        incomingSessions(b2),
        0,
        reason: 'zero requests that create a session reached the new key',
      );
      expect(b2.rx.existsSync() ? b2.rx.listSync() : const [], isEmpty);
      expect(
        a.sasCodes(outgoing: true),
        hasLength(1),
        reason: 'a SAS never overrides a pin mismatch',
      );
      expect(
        contactsOf(a)[b.deviceId]!.fingerprint,
        oldFp,
        reason: 'the pin is never replaced silently',
      );
    }, skip: skip);

    test('explicit removal of the contact, then the send works again through a new SAS and a new pin', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob', ip: '127.0.0.50');
      expect((await sendTo(a, b, [src('ok.bin', 100)])).isSuccess, isTrue);
      await rig.stop(b);
      final b2 = await rig.start(
        'Bob',
        deviceId: b.deviceId,
        ip: '127.0.0.50',
        idDir: Directory(p.join(sandbox.path, 'id-bob-new')),
      );
      await expectLater(
        sendTo(a, b2, [src('x.bin', 10)]),
        throwsA(isA<PeerFingerprintMismatchException>()),
      );

      await a.engine.removeContact(b.deviceId);
      expect(contactsOf(a).containsKey(b.deviceId), isFalse);
      final f = src('again.bin', 777, seed: 5);
      final res = await sendTo(a, b2, [f]);
      expect(res.isSuccess, isTrue, reason: '$res');
      expect(res.receiverFingerprint, b2.fp);
      expect(
        a.sasCodes(outgoing: true),
        hasLength(2),
        reason: 'first contact again, with a SAS',
      );
      expect(b2.sasCodes(outgoing: false), hasLength(1));
      expect(contactsOf(a)[b.deviceId]!.fingerprint, b2.fp);
      await expectSameFile(f, File(p.join(b2.rx.path, p.basename(f.path))));
    }, skip: skip);

    test('a pin taken from the trust store is enforced: a wrong pinned key for the device id is refused before a session exists', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob');
      await a.engine.addContact(
        deviceId: b.deviceId,
        fingerprint: '${'0' * 63}1',
        alias: 'Bob',
      );
      await expectLater(
        sendTo(a, b, [src('pinned.bin', 100)]),
        throwsA(isA<PeerFingerprintMismatchException>()),
      );
      expect(incomingSessions(b), 0);
      expect(b.rx.existsSync() ? b.rx.listSync() : const [], isEmpty);
      // Twin: with the right fingerprint pinned the very same send works, without any SAS.
      await a.engine.removeContact(b.deviceId);
      await a.engine.addContact(
        deviceId: b.deviceId,
        fingerprint: b.fp,
        alias: 'Bob',
      );
      final res = await sendTo(a, b, [src('pinned2.bin', 100)]);
      expect(res.isSuccess, isTrue, reason: '$res');
      expect(a.sasCodes(outgoing: true), isEmpty);
      expect(b.sasCodes(outgoing: false), isEmpty);
    }, skip: skip);

    test('sender with a new key and the same device id: the receiver answers KEY_CHANGED, nothing is accepted or pinned', () async {
      final a = await rig.start('Alice', ip: '127.0.0.60');
      final b = await rig.start('Bob'); // autoAccept: true on purpose
      expect((await sendTo(a, b, [src('ok.bin', 100)])).isSuccess, isTrue);
      final sessionsBefore = incomingSessions(b);
      final savedBefore = b.events.of<FileSaved>().length;
      final oldFp = a.fp;
      await rig.stop(a);

      final a2 = await rig.start(
        'Alice',
        deviceId: a.deviceId,
        ip: '127.0.0.60',
        idDir: Directory(p.join(sandbox.path, 'id-alice-new')),
      );
      expect(a2.fp, isNot(oldFp));
      final res = await sendTo(a2, b, [src('evil.bin', 100)]);

      expect(res.status, TransferStatus.failed);
      expect(res.isSuccess, isFalse);
      expect(
        res.refusal,
        LsErrorCode.keyChanged,
        reason: 'the CLI derives exit 80 from the refusal code',
      );
      final changed = await b.events.next<PeerKeyChanged>(
        what: 'PeerKeyChanged on the receiver',
      );
      expect(changed.deviceId, a.deviceId);
      expect(changed.pinnedFingerprint, oldFp);
      expect(changed.presentedFingerprint, a2.fp);
      expect(
        incomingSessions(b),
        sessionsBefore,
        reason: 'no session was created for the new key',
      );
      expect(b.events.of<FileSaved>(), hasLength(savedBefore));
      expect(
        contactsOf(b)[a.deviceId]!.fingerprint,
        oldFp,
        reason: 'pin not replaced',
      );
      expect(contactsOf(a2), isEmpty, reason: 'the refused sender pins nobody');
      expect(res.receiverFingerprint, isNull);
    }, skip: skip);
  });

  // block / unblock / remove / setTrust / contacts stream
  group('contact management on the engine', () {
    test('block: that fingerprint is refused (no session, REJECTED); unblock: it works again without a SAS', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob');
      expect((await sendTo(a, b, [src('ok.bin', 100)])).isSuccess, isTrue);
      final sessions = incomingSessions(b);

      await b.engine.block(a.fp);
      final blocked = await sendTo(a, b, [src('blocked.bin', 100)]);
      expect(blocked.status, TransferStatus.failed);
      expect(blocked.failureReason, FailureReason.rejected);
      expect(blocked.refusal, LsErrorCode.blocked, reason: 'CLI exit 82');
      expect(
        incomingSessions(b),
        sessions,
        reason: 'a blocked sender never creates a session',
      );

      await b.engine.unblock(a.fp);
      final again = await sendTo(a, b, [src('unblocked.bin', 100)]);
      expect(again.isSuccess, isTrue, reason: '$again');
      expect(
        a.sasCodes(outgoing: true),
        hasLength(1),
        reason: 'the pins survived the block',
      );
    }, skip: skip);

    test(
      'a stranger that is blocked before its first contact is refused as well',
      () async {
        final a = await rig.start('Alice');
        final b = await rig.start('Bob');
        await b.engine.block(a.fp);
        final res = await sendTo(a, b, [src('hello.bin', 100)]);
        expect(res.isSuccess, isFalse);
        expect(res.failureReason, FailureReason.rejected);
        expect(res.refusal, LsErrorCode.blocked, reason: 'CLI exit 82');
        expect(incomingSessions(b), 0);
        expect(
          a.sasCodes(outgoing: true),
          isEmpty,
          reason: 'refused before any SAS',
        );
      },
      skip: skip,
    );

    test(
      'addContact, setTrust, removeContact and the contacts stream',
      () async {
        final a = await rig.start('Alice');
        final id = newDeviceId();
        final fp = 'AB${'0' * 62}';
        final snapshots = <List<Contact>>[];
        final sub = a.engine.contacts.listen(snapshots.add);
        addTearDown(sub.cancel);
        await until(
          () => snapshots.isNotEmpty,
          what: 'contacts replays the current list on listen',
        );
        expect(snapshots.first, isEmpty);

        await a.engine.addContact(deviceId: id, fingerprint: fp, alias: 'Dana');
        expect(
          contactsOf(a)[id]!.trust,
          PeerTrust.known,
          reason: 'known unless told otherwise',
        );
        expect(contactsOf(a)[id]!.alias, 'Dana');
        await until(
          () => snapshots.any((s) => s.any((c) => c.deviceId == id)),
          what: 'stream shows the new contact',
        );

        await a.engine.setTrust(id, PeerTrust.trusted);
        expect(contactsOf(a)[id]!.trust, PeerTrust.trusted);
        await until(
          () => snapshots.last.any(
            (c) => c.deviceId == id && c.trust == PeerTrust.trusted,
          ),
          what: 'stream shows the new trust level',
        );

        await a.engine.removeContact(id);
        expect(contactsOf(a).containsKey(id), isFalse);
        await until(
          () => snapshots.last.every((c) => c.deviceId != id),
          what: 'stream shows the removal',
        );
      },
      skip: skip,
    );

    test(
      'addContact refuses a malformed fingerprint and does not store anything',
      () async {
        final a = await rig.start('Alice');
        await expectLater(
          a.engine.addContact(
            deviceId: newDeviceId(),
            fingerprint: 'not-hex',
            alias: 'X',
          ),
          throwsA(anything),
        );
        expect(contactsOf(a), isEmpty);
      },
      skip: skip,
    );

    test('the trust store is persistent: the pin of a restarted sender is still enforced', () async {
      final a = await rig.start('Alice', ip: '127.0.0.70');
      final b = await rig.start('Bob');
      expect((await sendTo(a, b, [src('ok.bin', 100)])).isSuccess, isTrue);
      final dir = a.idDir;
      final id = a.deviceId;
      final fpBefore = a.fp;
      await rig.stop(a);

      final a2 = await rig.start(
        'Alice',
        idDir: dir,
        deviceId: id,
        ip: '127.0.0.70',
      );
      expect(a2.fp, fpBefore);
      expect(contactsOf(a2)[b.deviceId]!.fingerprint, b.fp);
      final res = await sendTo(a2, b, [src('after-restart.bin', 100)]);
      expect(res.isSuccess, isTrue, reason: '$res');
      expect(
        a2.sasCodes(outgoing: true),
        isEmpty,
        reason: 'still pinned after the restart: no SAS',
      );
    }, skip: skip);
  });
}
