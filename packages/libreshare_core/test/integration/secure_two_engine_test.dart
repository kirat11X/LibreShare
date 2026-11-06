// P6a - two real engines in one process, plaintext profile and secure profile as twins:
// multi-file sessions (0 byte, 1 KiB, multi-chunk), byte-identical results, events on both sides,
// both directions, rejection, an eavesdropper on the wire, and the PIN policy through the facade.
//
// Spec: LSP-1 0.3 (the plaintext profile stays the Inc 1/2 behaviour), 4.4 (chunks), 5 (FR-05 mutual
// authentication: the bytes on the wire are TLS), 5.1 (first contact SAS, then pinned), 5.2 (PIN:
// required -> invalid -> five strikes -> BLOCKED even for the right PIN; trusted contacts exempt,
// known ones not), FR-07..FR-11, FR-17 of the plan (docs/plans/inc3.md section 4).
//
// SPEC-GAP: FileSender maps PIN_REQUIRED / PIN_INVALID / BLOCKED to FAILED(REJECTED), so the engine
// result for any PIN refusal is a failed SendResult with FailureReason.rejected, not an exception.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    sandbox = Directory.systemTemp.createTempSync('ls_p6a_two_');
    rig = P6aRig(sandbox);
  });
  tearDown(() async {
    await rig.dispose();
    sandbox.deleteSync(recursive: true);
  });

  File src(String name, int size, {int seed = 1}) => writeRandomFile(
    Directory(p.join(sandbox.path, 'src-${counter++}')),
    name,
    size,
    seed: seed,
    mtime: DateTime.utc(2024, 3, 15, 12, 34, 56),
  );

  int incomingSessions(P6aNode n) =>
      n.events.of<SessionCreated>().where((e) => !e.outgoing).length;

  for (final secure in [false, true]) {
    final profile = secure ? 'secure' : 'plaintext (Inc 1/2 twin)';

    group('$profile profile', () {
      test(
        'a multi-file session arrives byte-identical: 0 byte, 1 KiB, multi-chunk; no .lspart left; events on both sides',
        () async {
          final a = await rig.start('Alice', secure: secure);
          final b = await rig.start('Bob', secure: secure);
          final files = [
            src('empty.bin', 0),
            src('one-kib.bin', 1024, seed: 2),
            src('multi-chunk.bin', kChunkSize + 12345, seed: 3),
            src('Ünïcödé name.txt', 77, seed: 4),
          ];
          final total = files.fold<int>(0, (s, f) => s + f.lengthSync());

          final res = await sendTo(a, b, files);

          expect(res.isSuccess, isTrue, reason: '$res');
          expect(res.bytesSent, total);
          expect(res.receiverFingerprint, secure ? b.fp : isNull);
          for (final f in files) {
            await expectSameFile(
              f,
              File(p.join(b.rx.path, p.basename(f.path))),
            );
          }
          expect(
            b.rx.listSync(),
            hasLength(files.length),
            reason: 'nothing else in the download dir',
          );
          expect(
            leftovers(b.rx),
            isEmpty,
            reason: 'no .lspart or sidecar left',
          );

          // Sender: created, progress, one finished(success). Receiver: created, 4 saved, finished(success).
          expect(
            a.events.of<SessionCreated>().where((e) => e.outgoing),
            hasLength(1),
          );
          expect(a.events.of<FileProgress>(), isNotEmpty);
          expect(a.events.of<SessionFinished>().single.success, isTrue);
          expect(
            b.events.of<SessionCreated>().where((e) => !e.outgoing),
            hasLength(1),
          );
          expect(b.events.of<FileSaved>(), hasLength(files.length));
          expect(b.events.of<SessionFinished>().single.success, isTrue);
          expect(a.sasCodes(outgoing: true).length, secure ? 1 : 0);
          expect(b.sasCodes(outgoing: false).length, secure ? 1 : 0);
          expect(a.engine.identity != null, secure);
          expect(a.engine.currentContacts.length, secure ? 1 : 0);
        },
        skip: skip,
        timeout: const Timeout(Duration(seconds: 60)),
      );

      test(
        'both directions, one after the other and then at the same time',
        () async {
          final a = await rig.start('Alice', secure: secure);
          final b = await rig.start('Bob', secure: secure);
          final f1 = src('a-to-b.bin', 5000, seed: 5);
          final f2 = src('b-to-a.bin', 6000, seed: 6);
          expect((await sendTo(a, b, [f1])).isSuccess, isTrue);
          expect((await sendTo(b, a, [f2])).isSuccess, isTrue);
          await expectSameFile(f1, File(p.join(b.rx.path, 'a-to-b.bin')));
          await expectSameFile(f2, File(p.join(a.rx.path, 'b-to-a.bin')));

          final g1 = src('g1.bin', 40000, seed: 7);
          final g2 = src('g2.bin', 50000, seed: 8);
          final results = await Future.wait([
            sendTo(a, b, [g1]),
            sendTo(b, a, [g2]),
          ]);
          expect(results.every((r) => r.isSuccess), isTrue, reason: '$results');
          await expectSameFile(g1, File(p.join(b.rx.path, 'g1.bin')));
          await expectSameFile(g2, File(p.join(a.rx.path, 'g2.bin')));
          if (secure) {
            expect(
              b.sasCodes(outgoing: true),
              isEmpty,
              reason: 'B -> A after A -> B: both sides were pinned by then',
            );
          }
        },
        skip: skip,
      );

      test(
        'the receiver rejects: FAILED(REJECTED) on both sides, nothing written',
        () async {
          final a = await rig.start('Alice', secure: secure);
          final b = await rig.start(
            'Bob',
            secure: secure,
            autoAccept: false,
            acceptSas: false,
          );
          final send = a.engine.beginSendFiles(
            [src('no.bin', 300)],
            host: b.ip,
            port: b.port,
          );
          final created = await b.events.next<SessionCreated>(
            test: (e) => !e.outgoing,
          );
          if (secure) await b.events.next<SasReady>(test: (e) => !e.outgoing);
          await b.engine.receiver.reject(created.sessionId);

          final res = await send.result;
          expect(res.status, TransferStatus.failed);
          expect(res.failureReason, FailureReason.rejected);
          expect(b.rx.existsSync() ? b.rx.listSync() : const [], isEmpty);
          expect(b.events.of<FileSaved>(), isEmpty);
          expect(
            a.engine.currentContacts,
            isEmpty,
            reason: 'nobody is pinned by a rejected session',
          );
          expect(b.engine.currentContacts, isEmpty);
        },
        skip: skip,
      );
    });
  }

  // LSP-1 5: FR-05 on the wire.
  group('what an eavesdropper sees', () {
    final marker = utf8.encode(
      'LS-P6A-PLAINTEXT-MARKER-0123456789-abcdefghijklmnop',
    );

    File markerFile(String name) {
      final bytes = BytesBuilder();
      for (var i = 0; i < 100; i++) {
        bytes.add(marker);
      }
      final dir = Directory(p.join(sandbox.path, 'src-${counter++}'))
        ..createSync(recursive: true);
      return File(p.join(dir.path, name))..writeAsBytesSync(bytes.toBytes());
    }

    test('plaintext profile: the file bytes and the file name cross the wire in the clear (the tap can see)', () async {
      final a = await rig.start('Alice', secure: false);
      final b = await rig.start('Bob', secure: false);
      final tap = await TcpTap.start(b.ip, b.port);
      addTearDown(tap.close);
      final f = markerFile('visible-name.bin');
      final res = await a.engine.sendFiles([f], host: loopback, port: tap.port);
      expect(res.isSuccess, isTrue, reason: '$res');
      expect(tap.sawBytes(marker), isTrue);
      expect(tap.sawBytes(utf8.encode('visible-name.bin')), isTrue);
    }, skip: skip);

    test('secure profile: neither the file bytes nor the file name nor the alias appear on the wire; the file arrives intact', () async {
      final a = await rig.start('AliceVisibleAlias');
      final b = await rig.start('Bob');
      final tap = await TcpTap.start(b.ip, b.port);
      addTearDown(tap.close);
      final f = markerFile('hidden-name.bin');
      final res = await a.engine.sendFiles([f], host: loopback, port: tap.port);
      expect(res.isSuccess, isTrue, reason: '$res');
      expect(
        tap.captured.length,
        greaterThan(f.lengthSync()),
        reason: 'the tap saw the transfer',
      );
      expect(tap.sawBytes(marker), isFalse);
      expect(tap.sawBytes(utf8.encode('hidden-name.bin')), isFalse);
      expect(tap.sawBytes(utf8.encode('AliceVisibleAlias')), isFalse);
      expect(tap.sawBytes(utf8.encode('HTTP/1.1')), isFalse);
      await expectSameFile(f, File(p.join(b.rx.path, 'hidden-name.bin')));
      expect(
        res.receiverFingerprint,
        b.fp,
        reason:
            'the pin check ran against the real certificate through the tap',
      );
    }, skip: skip);
  });

  // LSP-1 5.2 through the facade: the receiver's PinGuard is the engine's.
  group('PIN policy (secure profile)', () {
    const pin = '424242';
    const fixed = PinPolicy(mode: PinMode.fixed);

    test('no PIN and a wrong PIN are refused (REJECTED, no session); the right PIN works through a SAS first contact', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob', pinPolicy: fixed, pin: pin);
      expect(b.engine.pinGuard!.enforced, isTrue);
      expect(b.engine.pinGuard!.currentPin, pin);

      final none = await sendTo(a, b, [src('n.bin', 10)]);
      expect(none.status, TransferStatus.failed);
      expect(none.failureReason, FailureReason.rejected);
      expect(none.refusal, LsErrorCode.pinRequired, reason: 'CLI exit 82');
      final wrong = await sendTo(a, b, [src('w.bin', 10)], pin: '000000');
      expect(wrong.status, TransferStatus.failed);
      expect(wrong.failureReason, FailureReason.rejected);
      expect(wrong.refusal, LsErrorCode.pinInvalid, reason: 'CLI exit 82');
      expect(
        incomingSessions(b),
        0,
        reason: 'no session before the PIN is right',
      );

      final f = src('ok.bin', 123, seed: 12);
      final ok = await sendTo(a, b, [f], pin: pin);
      expect(ok.isSuccess, isTrue, reason: '$ok');
      expect(a.sasCodes(outgoing: true), hasLength(1));
      await expectSameFile(f, File(p.join(b.rx.path, 'ok.bin')));
    }, skip: skip);

    test(
      'five wrong PINs block the source: the sixth, correct one is refused too',
      () async {
        final a = await rig.start('Alice');
        final b = await rig.start('Bob', pinPolicy: fixed, pin: pin);
        for (var i = 0; i < 5; i++) {
          final r = await sendTo(a, b, [src('w$i.bin', 10)], pin: '00000$i');
          expect(r.isSuccess, isFalse, reason: 'wrong PIN $i');
        }
        final sixth = await sendTo(a, b, [src('right.bin', 10)], pin: pin);
        expect(
          sixth.status,
          TransferStatus.failed,
          reason: 'blocked even for the correct PIN',
        );
        expect(incomingSessions(b), 0);
        expect(b.rx.existsSync() ? b.rx.listSync() : const [], isEmpty);
      },
      skip: skip,
    );

    test('a rotated PIN: the old one is refused, the new one works', () async {
      final a = await rig.start('Alice');
      final b = await rig.start('Bob', pinPolicy: fixed, pin: pin);
      b.engine.pinGuard!.rotate();
      final fresh = b.engine.pinGuard!.currentPin!;
      expect(fresh, isNot(pin));
      expect(
        (await sendTo(a, b, [src('old.bin', 10)], pin: pin)).isSuccess,
        isFalse,
      );
      expect(
        (await sendTo(a, b, [src('new.bin', 10)], pin: fresh)).isSuccess,
        isTrue,
      );
    }, skip: skip);

    test('a paired (trusted) contact is exempt from the PIN, a SAS-pinned (known) one is not', () async {
      final b = await rig.start('Bob', pinPolicy: fixed, pin: pin);
      final trusted = await rig.start('Trusted');
      final known = await rig.start('Known');

      // Trusted: pair through the invite flow.
      final redeem = trusted.engine.redeemPairInvite(
        b.engine.createPairInvite(),
      );
      await until(
        () => b.engine.pairing.pendingPrompt != null,
        what: 'pair prompt',
      );
      b.engine.pairing.decide(accept: true);
      expect(await redeem, isTrue);
      final viaPair = await sendTo(trusted, b, [src('t.bin', 10)]);
      expect(viaPair.isSuccess, isTrue, reason: 'exempt: $viaPair');

      // Known: first contact with the PIN, then the next one without it.
      expect(
        (await sendTo(known, b, [src('k1.bin', 10)], pin: pin)).isSuccess,
        isTrue,
      );
      expect(contactsOf(b)[known.deviceId]!.trust, PeerTrust.known);
      final again = await sendTo(known, b, [src('k2.bin', 10)]);
      expect(
        again.isSuccess,
        isFalse,
        reason: 'known is not trusted: the PIN is still required',
      );
      expect(again.failureReason, FailureReason.rejected);
      expect(again.refusal, LsErrorCode.pinRequired, reason: 'CLI exit 82');
    }, skip: skip);

    test(
      'without a PIN policy a PIN the sender offers is harmless (twin)',
      () async {
        final a = await rig.start('Alice');
        final b = await rig.start('Bob');
        expect(b.engine.pinGuard!.enforced, isFalse);
        expect(
          (await sendTo(a, b, [src('x.bin', 10)], pin: '123456')).isSuccess,
          isTrue,
        );
      },
      skip: skip,
    );
  });
}
