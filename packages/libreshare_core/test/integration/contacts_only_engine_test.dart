// P6a - Contacts-only end to end: discovery (in-memory bus) plus the pairing flow between two real
// engines over loopback TLS.
//
// Spec: LSP-1 4.2 rule 10 and 5.4 (a Contacts-only device multicasts nothing of its own, answers
// only contacts, and is a 404 to strangers on HTTPS), 5.3 (QR pairing: invite URI with `s=`, MAC
// proof, inviter decides, both sides pin each other as trusted and derive the same K_pair, S is single
// use and wrong MAC does not spend it, the route is exempt from the Contacts-only gate), plan
// section 4: "stranger invisible and 404, pair via invite/redeem makes the contact visible within a few
// seconds, removed contact invisible again".
//
// SPEC-GAP: `LibreShareEngine.redeemPairInvite(uri)` returns true when the inviter accepted, false when
// it declined (or the 125 s hold ran out); a refusal by the protocol (spent or unknown invite, bad
// proof, key conflict) is an LsException; a pinned certificate that differs from the invite's `fp=` is
// a PeerFingerprintMismatchException before any HTTP byte; a string that is not a libreshare://pair
// URI is a FormatException. `createPairInvite()` needs an open listener and an address (StateError).
// SPEC-GAP: whether removeContact also deletes the stored K_pair is not asserted.
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
    sandbox = Directory.systemTemp.createTempSync('ls_p6a_pair_');
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
    seed: 4,
  );

  bool lists(P6aNode who, P6aNode other) =>
      who.engine.currentDevices.any((d) => d.id == other.deviceId);

  Future<void> contactsOnly(P6aNode n) =>
      n.engine.receive.setVisibility(ReceiveVisibility.contacts);

  /// The inviter's user looks at the prompt and answers.
  Future<PairPrompt> decide(P6aNode inviter, {required bool accept}) async {
    await until(
      () => inviter.engine.pairing.pendingPrompt != null,
      what: 'inviter is asked to accept the pairing',
    );
    final prompt = inviter.engine.pairing.pendingPrompt!;
    inviter.engine.pairing.decide(accept: accept);
    return prompt;
  }

  // LSP-1 4.2 rule 10 and 5.4.
  group('a Contacts-only device is invisible to strangers', () {
    test(
      'twin: with visibility everyone the stranger lists the device within 5 s',
      () async {
        final b = await rig.start('Bob', discovery: true);
        final s = await rig.start('Stranger', discovery: true);
        await until(() => lists(s, b), what: 'stranger lists the open device');
        await until(() => lists(b, s), what: 'and the other way round');
      },
      skip: skip,
    );

    test('Contacts-only: no announcement of any kind, not listed by the stranger, 404 over HTTPS', () async {
      final b = await rig.start('Bob', discovery: true);
      await contactsOnly(b);
      final mark = rig.bus.sent.length;
      final s = await rig.start('Stranger', discovery: true);

      // Several announce rounds of the stranger (every 300 ms) pass.
      for (var i = 0; i < 12; i++) {
        await settle(150);
        expect(lists(s, b), isFalse, reason: 'invisible at round $i');
      }
      final since = rig.bus.sent.skip(mark).toList();
      expect(
        since.where((d) => decodeAnnounce(d.data)?.info.deviceId == b.deviceId),
        isEmpty,
        reason: 'a Contacts-only device sends neither announcements nor replies to strangers',
      );
      expect(
        since.where((d) => decodeAnnounce(d.data)?.info.deviceId == s.deviceId),
        isNotEmpty,
        reason: 'twin: the stranger itself did announce, so the bus recording works',
      );
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
    }, skip: skip);
  });

  // LSP-1 5.3.
  group('pairing', () {
    test(
      'invite, redeem, inviter accepts: both trusted, same K_pair, usable at once, visible within seconds, removal hides again',
      () async {
        final b = await rig.start(
          'Bob',
          discovery: true,
          peerExpiry: const Duration(seconds: 2),
        );
        await contactsOnly(b);
        final s = await rig.start(
          'Stranger',
          discovery: true,
          peerExpiry: const Duration(seconds: 2),
        );
        await settle();
        expect(lists(s, b), isFalse, reason: 'stranger before pairing');

        // The invite URI (LSP-1 5.3 / 4.2 rule 6).
        final uriText = b.engine.createPairInvite();
        final uri = Uri.parse(uriText);
        expect(uri.scheme, 'libreshare');
        expect(uri.host, 'pair');
        expect(uri.queryParameters['v'], '1');
        expect(
          uri.queryParameters['s'],
          matches(RegExp(r'^[A-Za-z0-9_-]{43}$')),
        );
        expect(uri.queryParameters['id'], b.deviceId);
        expect(uri.queryParameters['fp'], b.fp);
        expect(uri.queryParameters['n'], 'Bob');
        expect(uri.queryParameters['ip'], b.ip);
        expect(uri.queryParameters['port'], '${b.port}');
        expect(b.engine.pairing.hasActiveInvite, isTrue);

        // Scan: the inviter's user decides; Contacts-only does not block /pair.
        final redeem = s.engine.redeemPairInvite(uriText);
        final prompt = await decide(b, accept: true);
        expect(prompt.sender.alias, 'Stranger');
        expect(prompt.fingerprint, s.fp);
        expect(await redeem, isTrue);
        expect(b.engine.pairing.hasActiveInvite, isFalse, reason: 'single use');

        final cb = contactsOf(b)[s.deviceId];
        final cs = contactsOf(s)[b.deviceId];
        expect(cb, isNotNull);
        expect(cs, isNotNull);
        expect(cb!.trust, PeerTrust.trusted);
        expect(cs!.trust, PeerTrust.trusted);
        expect(cb.fingerprint, s.fp);
        expect(cs.fingerprint, b.fp);
        expect(cb.alias, 'Stranger');
        expect(cs.alias, 'Bob');
        expect(cb.hasPairKey, isTrue);
        expect(cs.hasPairKey, isTrue);
        await b.events.next<ContactChanged>(
          test: (e) => e.deviceId == s.deviceId,
        );
        await s.events.next<ContactChanged>(
          test: (e) => e.deviceId == b.deviceId,
        );

        final kB = await b.wiring!.secrets.get('kpair/${s.deviceId}');
        final kS = await s.wiring!.secrets.get('kpair/${b.deviceId}');
        expect(kB, isNotNull);
        expect(kB, hasLength(32));
        expect(kS, kB, reason: 'both ends derived the same K_pair');

        // "Visible within a few seconds."
        await until(
          () => lists(s, b),
          timeout: const Duration(seconds: 6),
          what: 'paired contact becomes visible',
        );

        // And usable at once, without any SAS.
        final f = src('after-pairing.bin', 2048);
        final res = await sendTo(s, b, [f]);
        expect(res.isSuccess, isTrue, reason: '$res');
        expect(s.sasCodes(outgoing: true), isEmpty);
        expect(b.sasCodes(outgoing: false), isEmpty);
        await expectSameFile(f, File(p.join(b.rx.path, p.basename(f.path))));

        // Removal: 404 at once, off the list after the peer expiry.
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
        await until(
          () => !lists(s, b),
          timeout: const Duration(seconds: 14),
          what: 'removed contact is invisible again',
        );
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('the inviter declines: redeem returns false, nobody is pinned, the invite is spent', () async {
      final b = await rig.start('Bob');
      await contactsOnly(b);
      final s = await rig.start('Stranger');
      final uri = b.engine.createPairInvite();
      final redeem = s.engine.redeemPairInvite(uri);
      await decide(b, accept: false);
      expect(await redeem, isFalse);
      expect(contactsOf(b), isEmpty);
      expect(contactsOf(s), isEmpty);
      expect(b.engine.pairing.hasActiveInvite, isFalse);
      await expectLater(
        s.engine.redeemPairInvite(uri),
        throwsA(isA<LsException>()),
      );
    }, skip: skip);

    test('a spent invite cannot be used by a second scanner', () async {
      final b = await rig.start('Bob');
      final s = await rig.start('One');
      final t = await rig.start('Two');
      final uri = b.engine.createPairInvite();
      final first = s.engine.redeemPairInvite(uri);
      await decide(b, accept: true);
      expect(await first, isTrue);
      await expectLater(
        t.engine.redeemPairInvite(uri),
        throwsA(
          isA<LsException>().having(
            (e) => e.code,
            'code',
            LsErrorCode.notFound,
          ),
        ),
      );
      expect(contactsOf(t), isEmpty);
      expect(contactsOf(b).keys, [s.deviceId]);
    }, skip: skip);

    test('a wrong secret is refused with AUTH_INVALID and does not spend the invite', () async {
      final b = await rig.start('Bob');
      final s = await rig.start('Stranger');
      final good = b.engine.createPairInvite();
      final goodUri = Uri.parse(good);
      final badSecret = goodUri.queryParameters['s']!.split('').reversed.join();
      final bad = goodUri
          .replace(
            queryParameters: {...goodUri.queryParameters, 's': badSecret},
          )
          .toString();

      await expectLater(
        s.engine.redeemPairInvite(bad),
        throwsA(
          isA<LsException>().having(
            (e) => e.code,
            'code',
            LsErrorCode.authInvalid,
          ),
        ),
      );
      expect(
        b.engine.pairing.pendingPrompt,
        isNull,
        reason: 'the inviter was never bothered',
      );
      expect(contactsOf(b), isEmpty);
      expect(b.engine.pairing.hasActiveInvite, isTrue);

      final redeem = s.engine.redeemPairInvite(good);
      await decide(b, accept: true);
      expect(await redeem, isTrue, reason: 'twin: the real secret still works');
    }, skip: skip);

    test('an invite whose fp= is not the listener certificate is refused before any HTTP byte', () async {
      final b = await rig.start('Bob');
      final other = await rig.start('Other');
      final s = await rig.start('Stranger');
      final good = Uri.parse(b.engine.createPairInvite());
      final forged = good
          .replace(queryParameters: {...good.queryParameters, 'fp': other.fp})
          .toString();
      await expectLater(
        s.engine.redeemPairInvite(forged),
        throwsA(isA<PeerFingerprintMismatchException>()),
      );
      expect(b.engine.pairing.pendingPrompt, isNull);
      expect(contactsOf(s), isEmpty);
    }, skip: skip);

    test('things that are not pair invites are FormatExceptions; nothing is stored', () async {
      final b = await rig.start('Bob');
      final s = await rig.start('Stranger');
      for (final bad in [
        '',
        'hello',
        'libreshare://peer?ip=${b.ip}&port=${b.port}',
        'libreshare://pair?v=1',
        'https://example.org/pair?s=x',
      ]) {
        await expectLater(
          s.engine.redeemPairInvite(bad),
          throwsA(isA<FormatException>()),
          reason: 'input "$bad"',
        );
      }
      expect(contactsOf(s), isEmpty);
    }, skip: skip);

    test(
      'no invite while the listener is closed (Receive Off): StateError',
      () async {
        final b = await rig.start('Bob');
        expect(b.engine.createPairInvite(), startsWith('libreshare://pair?'));
        await b.engine.receive.turnOff();
        expect(() => b.engine.createPairInvite(), throwsStateError);
      },
      skip: skip,
    );

    test('pairing a blocked fingerprint is refused (BLOCKED) and nothing is pinned', () async {
      final b = await rig.start('Bob');
      final s = await rig.start('Stranger');
      await b.engine.block(s.fp);
      final redeem = s.engine.redeemPairInvite(b.engine.createPairInvite());
      await expectLater(
        redeem,
        throwsA(
          isA<LsException>().having((e) => e.code, 'code', LsErrorCode.blocked),
        ),
      );
      expect(contactsOf(b), isEmpty);
      expect(contactsOf(s), isEmpty);
    }, skip: skip);
  });
}
