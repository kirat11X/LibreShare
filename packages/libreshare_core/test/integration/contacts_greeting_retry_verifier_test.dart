// VERIFIER test (not the tester's file): E5 R4c, written by the verifier agent 2026-11-06.
// Closes mutation gaps of contacts_greeting_retry_test.dart: timers cancelled on stop, retry state
// cleaned on removal / re-listing, bounded attempts (~40 s window), retry stops when Contacts-only
// is switched off, a stranger is never greeted after a trust change. Round 2: no dart:mirrors; uses
// the @visibleForTesting getters of LibreShareEngine (greetingRetryPendingCount,
// greetingRetryActiveTimerCount, greetedFingerprints) and a Zone createTimer hook.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p6a_support.dart';

Future<void> main() async {
  final skip = await p6aSkipReason();
  late Directory sandbox;
  late P6aRig rig;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ls_r4c_ver_');
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

  Future<(P6aNode bob, P6aNode sam)> asymmetric() async {
    final bob = await rig.start('Bob', discovery: true);
    await contactsOnly(bob);
    final sam = await rig.start('Sam', discovery: true);
    await until(() => lists(bob, sam), what: 'Bob lists Sam');
    await settle(600);
    expect(lists(sam, bob), isFalse);
    return (bob, sam);
  }

  int pending(P6aNode n) => n.engine.greetingRetryPendingCount;

  test('VERIFIER timers-cancelled-on-stop: every pending retry Timer is inactive after the engine stops', () async {
    // Every Timer created by LibreShareEngine._greet is captured through a Zone hook, so the
    // check does not depend on the engine's own map (stop() clears it after cancelling).
    final greetTimers = <Timer>[];
    final spec = ZoneSpecification(
      createTimer: (self, parent, zone, duration, f) {
        final t = parent.createTimer(zone, duration, f);
        if (StackTrace.current.toString().contains('_greet')) {
          greetTimers.add(t);
        }
        return t;
      },
    );
    await runZoned(() async {
      final (bob, sam) = await asymmetric();
      await contactsOnly(sam);
      await pin(bob, sam); // refused, retry chain starts
      await until(() => pending(bob) > 0, what: 'a retry timer is pending');
      expect(bob.engine.greetingRetryActiveTimerCount, greaterThan(0));
      expect(greetTimers.where((t) => t.isActive), isNotEmpty);
      final engine = bob.engine;
      await rig.stop(bob);
      expect(
        greetTimers.where((t) => t.isActive),
        isEmpty,
        reason: 'stop() must cancel the retry timers',
      );
      expect(engine.greetingRetryActiveTimerCount, 0);
      expect(engine.greetingRetryPendingCount, 0);
    }, zoneSpecification: spec);
  }, skip: skip);

  test('VERIFIER state-cleaned-on-removal-and-relisting: removal drops the retry timer and the greeted mark; re-adding starts a fresh cycle that is delivered', () async {
    final (bob, sam) = await asymmetric();
    await contactsOnly(sam);
    await pin(bob, sam);
    await until(() => pending(bob) > 0, what: 'retry pending');
    await bob.engine.removeContact(sam.deviceId);
    await settle(100);
    expect(pending(bob), 0, reason: 'timer of a removed contact');
    expect(
      bob.engine.greetedFingerprints,
      isEmpty,
      reason: 'greeted mark of a removed contact',
    );
    await pin(sam, bob); // Sam would accept now
    await pin(bob, sam); // re-listed as a contact: a new greeting cycle
    await until(
      () => lists(sam, bob),
      timeout: const Duration(seconds: 3),
      what: 'fresh cycle delivers',
    );
    expect(pending(bob), 0);
  }, skip: skip);

  test(
    'VERIFIER retry-bounded: with a contact that never accepts, the retry chain ends by itself within ~45 s and does not re-arm',
    () async {
      final (bob, sam) = await asymmetric();
      await contactsOnly(sam);
      await pin(bob, sam);
      await until(() => pending(bob) > 0, what: 'retry pending');
      // The chain ends after ~40 s of back-off (+ attempt times). The map is momentarily empty
      // while a POST is in flight, so wait past the end and then sample the map for 12 s (longer
      // than the longest back-off step): it must be empty at EVERY sample.
      await settle(46000);
      var nonEmptySamples = 0;
      for (var i = 0; i < 240; i++) {
        if (pending(bob) > 0) nonEmptySamples++;
        await settle(50);
      }
      expect(
        nonEmptySamples,
        0,
        reason:
            'a retry timer is still being armed after the back-off schedule',
      );
      expect(lists(sam, bob), isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test('VERIFIER retry-stops-when-contacts-only-switched-off: Bob goes back to Everyone (multicast and unicast lost), Sam pins Bob afterwards: no late greeting arrives', () async {
    final (bob, sam) = await asymmetric();
    await contactsOnly(sam);
    await pin(bob, sam); // refused, retries start
    await settle(300);
    rig.bus.dropMulticast = true;
    rig.bus.dropUnicast = true;
    await bob.engine.receive.setVisibility(ReceiveVisibility.everyone);
    await pin(sam, bob);
    await settle(6000);
    expect(
      lists(sam, bob),
      isFalse,
      reason: 'retry must stop once Bob is no longer Contacts-only',
    );
    expect(pending(bob), 0);
  }, skip: skip);

  test('VERIFIER greet-only-contacts-after-trust-change: a trust change while an open stranger is listed must not greet the stranger', () async {
    // The tester's greet-only-contacts test never triggers _greetContacts (it runs only on trust
    // changes), so it cannot see a "greet everybody" mutation. Here a trust change is forced by
    // adding an unrelated contact while stranger Sam (open, not a contact) is listed at Bob.
    final (bob, sam) = await asymmetric();
    await bob.engine.addContact(
      deviceId: newDeviceId(),
      fingerprint: 'AB' * 32,
      alias: 'Eve',
    );
    await settle(3000);
    expect(
      lists(sam, bob),
      isFalse,
      reason: 'Sam is a stranger: nothing may be sent to him',
    );
    expect(bob.engine.greetedFingerprints, isEmpty);
  }, skip: skip);
}
