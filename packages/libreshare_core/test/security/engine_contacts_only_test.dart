// P6a - Contacts-only visibility through the engine: ReceiveController no longer throws, the flag
// reaches the ApiServer gate per request, and the contact list decides who is served.
//
// Spec: LSP-1 5.4 (a stranger gets the 404 of an unknown route on GET /info, POST /register and
// POST /sessions, even with a valid proof; a contact is served after full verification; removing a
// contact makes it 404 again), docs/plans/inc3.md section 10 item 4 (the UnsupportedError in
// ReceiveController is removed), design 01 section 1.3. The server-level byte-for-byte checks live in
// security/contacts_only_server_test; this file proves the engine wiring.
//
// SPEC-GAP: in the plaintext profile there is no trust store, so Contacts-only stays unsupported
// there (UnsupportedError, as before Increment 3).
// SPEC-GAP: a sender that has NOT pinned a Contacts-only receiver sends an unauthenticated
// `GET /info` (an unpinned client never signs it), which is a stranger's request and gets the 404,
// even if the receiver lists the sender as a contact. First contact with a Contacts-only device
// therefore goes through pairing (integration/contacts_only_engine_test), not through a plain send.
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
  var counter = 0;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ls_p6a_contacts_');
    rig = P6aRig(sandbox);
  });
  tearDown(() async {
    await rig.dispose();
    sandbox.deleteSync(recursive: true);
  });

  File src(String name, int size) => writeRandomFile(
    Directory(p.join(sandbox.path, 'src')),
    '${counter++}-$name',
    size,
    seed: 3,
  );

  int incomingSessions(P6aNode n) =>
      n.events.of<SessionCreated>().where((e) => !e.outgoing).length;

  /// Both pinned: the receiver lists the sender, the sender pinned the receiver.
  Future<void> befriend(P6aNode receiver, P6aNode sender) async {
    await receiver.engine.addContact(
      deviceId: sender.deviceId,
      fingerprint: sender.fp,
      alias: sender.name,
    );
    await sender.engine.addContact(
      deviceId: receiver.deviceId,
      fingerprint: receiver.fp,
      alias: receiver.name,
    );
  }

  Future<void> contactsOnly(P6aNode n) =>
      n.engine.receive.setVisibility(ReceiveVisibility.contacts);

  group('ReceiveController accepts Contacts-only in the secure profile', () {
    test('setVisibility(contacts) works, is reflected in the state and can be undone', () async {
      final b = await rig.start('Bob');
      await contactsOnly(b);
      final st = b.engine.receive.state;
      expect(st, isA<On>());
      expect((st as On).visibility, ReceiveVisibility.contacts);
      expect(b.engine.receive.settings.visibility, ReceiveVisibility.contacts);
      expect(b.engine.isListening, isTrue, reason: 'the listener stays bound');
      await b.engine.receive.setVisibility(ReceiveVisibility.everyone);
      expect(
        (b.engine.receive.state as On).visibility,
        ReceiveVisibility.everyone,
      );
    }, skip: skip);

    test(
      'the plaintext profile still refuses it (no trust store to evaluate)',
      () async {
        final legacy = await rig.start('Legacy', secure: false);
        await expectLater(
          legacy.engine.receive.setVisibility(ReceiveVisibility.contacts),
          throwsA(isA<UnsupportedError>()),
        );
        expect(
          legacy.engine.receive.settings.visibility,
          ReceiveVisibility.everyone,
        );
      },
      skip: skip,
    );
  });

  // LSP-1 5.4 and 4.3.2: the gate is evaluated per request from the live flag.
  group('the gate follows the visibility setting per request', () {
    test('GET /info: 200 for everyone, the unknown-route 404 for a stranger while Contacts-only, 200 again after', () async {
      final b = await rig.start('Bob');
      Future<({int status, String body})> info() async {
        final r = await rawGet(b.ip, b.port, '$kApiPrefix/info');
        return (status: r.status, body: r.body);
      }

      final open = await info();
      expect(
        open.status,
        200,
        reason: 'twin: the harness can see a served answer',
      );
      expect(open.body, contains(b.deviceId));

      await contactsOnly(b);
      final closed = await info();
      final unknown = await rawGet(b.ip, b.port, '$kApiPrefix/no-such-route');
      expect(closed.status, 404);
      expect(
        closed.body,
        unknown.body,
        reason: 'no oracle: the envelope of an unknown route',
      );
      expect(closed.body, isNot(contains(b.deviceId)));

      await b.engine.receive.setVisibility(ReceiveVisibility.everyone);
      expect((await info()).status, 200);
    }, skip: skip);

    test('a stranger engine cannot read /info (404 as LsException) and cannot send; nothing is created', () async {
      final b = await rig.start('Bob');
      final s = await rig.start('Stranger');
      await contactsOnly(b);

      await expectLater(
        s.engine.peerInfo(b.ip, b.port),
        throwsA(
          isA<LsException>().having(
            (e) => e.code,
            'code',
            LsErrorCode.notFound,
          ),
        ),
      );
      final res = await sendTo(s, b, [src('hi.bin', 100)]);
      expect(res.isSuccess, isFalse);
      expect(res.status, TransferStatus.failed);
      expect(incomingSessions(b), 0);
      expect(b.rx.existsSync() ? b.rx.listSync() : const [], isEmpty);
      expect(
        contactsOf(b),
        isEmpty,
        reason: 'a refused stranger is not remembered',
      );
      expect(s.sasCodes(outgoing: true), isEmpty);
    }, skip: skip);

    test('a contact that both sides pinned is served: info and a full transfer without a SAS', () async {
      final b = await rig.start('Bob');
      final s = await rig.start('Sam');
      await befriend(b, s);
      await contactsOnly(b);

      final info = await s.engine.peerInfo(b.ip, b.port);
      expect(info.deviceId, b.deviceId);
      expect(info.fingerprint, b.fp);

      final f = src('served.bin', 3000);
      final res = await sendTo(s, b, [f]);
      expect(res.isSuccess, isTrue, reason: '$res');
      expect(s.sasCodes(outgoing: true), isEmpty);
      await expectSameFile(f, File(p.join(b.rx.path, p.basename(f.path))));
    }, skip: skip);

    test('removing the contact makes the very next request a 404 again; re-adding serves it again', () async {
      final b = await rig.start('Bob');
      final s = await rig.start('Sam');
      await befriend(b, s);
      await contactsOnly(b);
      expect((await s.engine.peerInfo(b.ip, b.port)).deviceId, b.deviceId);

      await b.engine.removeContact(s.deviceId);
      await expectLater(
        s.engine.peerInfo(b.ip, b.port),
        throwsA(
          isA<LsException>().having(
            (e) => e.code,
            'code',
            LsErrorCode.notFound,
          ),
        ),
      );
      final refused = await sendTo(s, b, [src('late.bin', 10)]);
      expect(refused.isSuccess, isFalse);
      expect(incomingSessions(b), 0);

      await b.engine.addContact(
        deviceId: s.deviceId,
        fingerprint: s.fp,
        alias: 'Sam',
      );
      expect((await s.engine.peerInfo(b.ip, b.port)).deviceId, b.deviceId);
    }, skip: skip);

    test('a blocked contact is a stranger again', () async {
      final b = await rig.start('Bob');
      final s = await rig.start('Sam');
      await befriend(b, s);
      await contactsOnly(b);
      await b.engine.block(s.fp);
      await expectLater(
        s.engine.peerInfo(b.ip, b.port),
        throwsA(
          isA<LsException>().having(
            (e) => e.code,
            'code',
            LsErrorCode.notFound,
          ),
        ),
      );
      await b.engine.unblock(s.fp);
      expect((await s.engine.peerInfo(b.ip, b.port)).deviceId, b.deviceId);
    }, skip: skip);

    test(
      'a contact whose key changed is a stranger (the pin names the old key)',
      () async {
        final b = await rig.start('Bob');
        final s = await rig.start('Sam', ip: '127.0.0.80');
        await befriend(b, s);
        await rig.stop(s);
        final s2 = await rig.start(
          'Sam',
          deviceId: s.deviceId,
          ip: '127.0.0.80',
          idDir: Directory(p.join(sandbox.path, 'id-sam-new')),
        );
        // s2 pins Bob (so it signs its /info), but Bob's pin for this device id names the old key.
        await s2.engine.addContact(
          deviceId: b.deviceId,
          fingerprint: b.fp,
          alias: 'Bob',
        );
        await contactsOnly(b);
        await expectLater(
          s2.engine.peerInfo(b.ip, b.port),
          throwsA(
            isA<LsException>().having(
              (e) => e.code,
              'code',
              LsErrorCode.notFound,
            ),
          ),
        );
      },
      skip: skip,
    );

    test('Bob lists Sam but Sam never pinned Bob: Sam is a stranger on the unsigned /info (SPEC-GAP)', () async {
      final b = await rig.start('Bob');
      final s = await rig.start('Sam');
      await b.engine.addContact(
        deviceId: s.deviceId,
        fingerprint: s.fp,
        alias: 'Sam',
      );
      await contactsOnly(b);
      final res = await sendTo(s, b, [src('x.bin', 10)]);
      expect(res.isSuccess, isFalse);
      expect(incomingSessions(b), 0);
    }, skip: skip);

    test('the plaintext twin: with visibility everyone a stranger sends freely (harness control)', () async {
      final b = await rig.start('Bob');
      final s = await rig.start('Sam');
      final res = await sendTo(s, b, [src('free.bin', 10)]);
      expect(res.isSuccess, isTrue, reason: '$res');
    }, skip: skip);
  });
}
