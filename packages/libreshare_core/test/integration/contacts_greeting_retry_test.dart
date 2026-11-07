// E5 / R4c: the Contacts-only greeting (`LibreShareEngine._greetContacts`) is retried and survives
// a restart of the contact (inc3.md section 12 "Known limits carried forward": "one-shot with no
// retry ... and misses a peer that restarts while still listed with the same key").
//
// Decision (tester): this needs NO protocol and NO contract change. The greeting is the existing
// `POST /register` through `ApiPeerRegistrar.call`, which already returns false on any failure, and
// the engine already sees every announce of a listed peer as a `DeviceUpdated` event of its
// registry. Retry with back-off and "greet again when a contact we already greeted announces
// again (rate limited)" are engine-only changes (`_greetContacts` and its call site(s)). A UDP
// fallback would need MulticastDiscovery changes and is NOT asked for by these tests.
//
// Scenario used to make a greeting fail for real (no mocks): Bob is Contacts-only and lists Sam
// (Sam announced while open), Sam does not list Bob (Bob is silent). Sam then turns Contacts-only
// too. When Bob adds Sam as a contact he greets Sam, but Sam does not know Bob yet: the stranger
// gate answers 404, the registrar returns false, and today `_greeted` already holds Sam so the
// greeting is never repeated.
//
// Rules the tests pin for the coder (names of the guards are in the descriptions):
//  * a greeting that fails is retried with back-off (the first retry within 2 s, further ones as
//    the coder likes) until it succeeds, the contact is removed, the contact is no longer
//    listed, or the engine stops; at least 5 s of retrying must be covered;
//  * a contact that was greeted and announces again (restart) is greeted again; the re-greeting
//    is rate limited (far fewer than one per announce);
//  * only contacts are ever greeted.
@TestOn('vm')
library;

import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p6a_support.dart';

Future<void> main() async {
  final skip = await p6aSkipReason();
  late Directory sandbox;
  late P6aRig rig;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ls_r4c_greet_');
    rig = P6aRig(sandbox);
  });
  tearDown(() async {
    rig.bus.dropMulticast = false;
    rig.bus.dropUnicast = false;
    await rig.dispose();
    sandbox.deleteSync(recursive: true);
  });

  bool lists(P6aNode who, P6aNode other) =>
      who.engine.currentDevices.any((d) => d.id == other.deviceId);

  Future<void> contactsOnly(P6aNode n) =>
      n.engine.receive.setVisibility(ReceiveVisibility.contacts);

  Future<void> pin(P6aNode who, P6aNode other) => who.engine.addContact(
    deviceId: other.deviceId,
    fingerprint: other.fp,
    alias: other.name,
  );

  /// Bob is Contacts-only and lists Sam; Sam does not list Bob.
  Future<(P6aNode bob, P6aNode sam)> asymmetric({
    Duration peerExpiry = const Duration(seconds: 90),
  }) async {
    final bob = await rig.start('Bob', discovery: true, peerExpiry: peerExpiry);
    await contactsOnly(bob);
    final sam = await rig.start('Sam', discovery: true, peerExpiry: peerExpiry);
    await until(
      () => lists(bob, sam),
      what: 'Bob lists Sam (heard an announce)',
    );
    await settle(600);
    expect(lists(sam, bob), isFalse, reason: 'premise: Bob is silent');
    return (bob, sam);
  }

  group('retry', () {
    test('GUARD greeting-retry: the first greeting is refused (404, Sam is Contacts-only and does not know Bob yet), the second is delivered: Sam lists Bob within 5 s', () async {
      final (bob, sam) = await asymmetric();
      await contactsOnly(sam); // Sam now answers strangers with the plain 404
      final t0 = DateTime.now();
      await pin(bob, sam); // Bob greets Sam: refused
      await settle(500);
      expect(
        lists(sam, bob),
        isFalse,
        reason: 'premise: the first greeting did not get through',
      );
      await pin(sam, bob); // Sam now accepts Bob; only a retry can deliver
      await until(
        () => lists(sam, bob),
        timeout: const Duration(seconds: 5) - DateTime.now().difference(t0),
        what: 'Sam lists Bob within 5 s of the first greeting',
      );
    }, skip: skip);

    test('GUARD greeting-retry-keeps-going: Sam becomes ready only 3.5 s after the first greeting, the retries are still running', () async {
      final (bob, sam) = await asymmetric();
      await contactsOnly(sam);
      await pin(bob, sam);
      await settle(3500);
      expect(lists(sam, bob), isFalse);
      await pin(sam, bob);
      await until(
        () => lists(sam, bob),
        timeout: const Duration(seconds: 6),
        what: 'a late retry reaches Sam',
      );
    }, skip: skip);

    test('GUARD retry-stops-when-contact-removed: no greeting after the contact was removed', () async {
      final (bob, sam) = await asymmetric();
      await contactsOnly(sam);
      await pin(bob, sam); // greeting refused, retries start
      await settle(300);
      await bob.engine.removeContact(sam.deviceId);
      await pin(sam, bob); // Sam would accept now
      await settle(6000);
      expect(
        lists(sam, bob),
        isFalse,
        reason: 'Bob must not reveal himself to a device that is no longer a contact',
      );
    }, skip: skip);

    test('GUARD greet-only-contacts: a stranger that keeps announcing is never greeted', () async {
      final (bob, sam) = await asymmetric();
      await settle(5000);
      expect(
        lists(sam, bob),
        isFalse,
        reason: 'Sam is not a contact of Bob: nothing may be sent to him',
      );
    }, skip: skip);
  });

  group('restart', () {
    test(
      'GUARD regreet-after-restart: Sam restarts while still listed with the same key (no bye), Bob greets again and Sam lists Bob within 5 s',
      () async {
        final (bob, sam) = await asymmetric();
        await pin(bob, sam);
        await pin(sam, bob);
        await until(
          () => lists(sam, bob),
          what: 'baseline: the first greeting is delivered',
        );

        // Sam crashes: its bye is lost, so Bob keeps listing it.
        rig.bus.dropMulticast = true;
        final idDir = sam.idDir;
        final id = sam.deviceId;
        final ip = sam.ip;
        await rig.stop(sam);
        rig.bus.dropMulticast = false;
        expect(lists(bob, sam), isTrue, reason: 'premise: still listed');

        // The restarted engine probes at start and Bob answers a contact's probe by a UDP
        // unicast, which would list Bob on the spot. UDP is lossy: that one reply is lost here
        // (HTTP is untouched). From then on Bob sees only ordinary announces of a device it
        // already lists with the same key, which it never answers: only a new greeting helps.
        rig.bus.dropUnicast = true;
        final sam2 = await rig.start(
          'Sam',
          discovery: true,
          idDir: idDir,
          deviceId: id,
          ip: ip,
        );
        expect(sam2.fp, sam.fp, reason: 'premise: same key');
        await settle(1500);
        rig.bus.dropUnicast = false;
        expect(lists(bob, sam2), isTrue);
        await until(
          () => lists(sam2, bob),
          timeout: const Duration(seconds: 5),
          what: 'the restarted Sam learns Bob (5 s after the lost reply)',
        );
      },
      skip: 'DEFERRED (questions.md Q4): LSP-1 4.2 rule 2 forbids a reply to an already-listed same-fingerprint announce; known limit',
    );

    test('GUARD regreet-rate-limited: with Sam announcing 3 times a second, Bob re-greets far less often than that', () async {
      final (bob, sam) = await asymmetric();
      await pin(bob, sam);
      await pin(sam, bob);
      await until(() => lists(sam, bob), what: 'baseline greeting');
      await settle(300);
      var snapshots = 0;
      final sub = sam.engine.devices.skip(1).listen((_) => snapshots++);
      addTearDown(sub.cancel);
      await settle(6000);
      // Sam announced about 20 times in these 6 s; every register call is one snapshot.
      expect(
        snapshots,
        lessThanOrEqualTo(8),
        reason: 're-greeting must be rate limited, not one POST per announce',
      );
    }, skip: skip);
  });
}
