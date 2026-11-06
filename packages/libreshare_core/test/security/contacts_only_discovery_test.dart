// P6b - the discovery half of Contacts-only visibility. The HTTPS gate (404 for
// strangers) is the server's job (P3/P6a); here: who gets an answer to a UDP
// probe or announce, and that a Contacts-only device announces nothing.
//
// Spec: LSP-1 4.2 rule 10 and 5.4 ("no periodic multicast, no mDNS
// registration; a probe is answered only for a contact's fingerprint"; a
// contact is a trust-store entry that is neither unknown nor blocked),
// docs/plans/inc3.md section 4.1 row `security/contacts_only_test`
// (`probe_from_untrusted_fingerprint_unanswered`, `no_mdns_no_periodic_announce`)
// and risk R6 (the fingerprint claim is unauthenticated: privacy only).
// The mDNS half of `no_mdns_no_periodic_announce` is engine wiring (P6a).
//
// New symbols under test:
//   MulticastDiscovery(security: SecurityConfig, contactsOnly: bool Function()?)
//   PeerRegistry(trust:) is used through P6bNode.
import 'dart:async';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:test/test.dart';

import '../helpers/p6b_support.dart';

void main() {
  late P6bPeer me;
  late P6bPeer friend;
  late P6bPeer stranger;
  late P6bPeer enemy;

  setUpAll(() {
    me = P6bPeer('co-me');
    friend = P6bPeer('co-friend');
    stranger = P6bPeer('co-stranger');
    enemy = P6bPeer('co-enemy');
  });

  late InMemoryMulticastBus bus;
  late bool contactsOnly;
  late List<String>
  registered; // deviceIds the registrar was asked to register with
  late P6bBare prober;
  late P6bNode rx;

  Future<void> start({
    bool withRegistrar = false,
    List<Duration> schedule = const [],
    Duration periodic = const Duration(hours: 1),
  }) async {
    rx = P6bNode(
      bus,
      me,
      probes: true,
      contactsOnly: () => contactsOnly,
      registrar: withRegistrar
          ? (peer, address) async {
              registered.add(peer.deviceId);
              return true;
            }
          : null,
      schedule: schedule,
      periodic: periodic,
    );
    await rx.discovery.start();
    addTearDown(rx.dispose);
    await prober.start();
    await settle();
    bus.sent.clear();
    prober.received.clear();
  }

  setUp(() {
    bus = InMemoryMulticastBus();
    contactsOnly = true;
    registered = [];
    prober = P6bBare(bus, address: '10.0.0.50');
  });

  Future<void> pinFriend({PeerTrust level = PeerTrust.known}) => rx.trust.pin(
    deviceId: friend.id,
    fingerprint: friend.fp,
    alias: 'Friend',
    trust: level,
  );

  /// Unicast datagrams the receiver sent to the prober, decoded.
  List<AnnounceMessage> replies() => [
    for (final s in bus.unicasts)
      if (s.to?.address == '10.0.0.50') ?decodeAnnounce(s.data),
  ];

  Future<void> probe(P6bPeer who, {String? fingerprint}) async {
    prober.announce(who.info(port: 0, fingerprint: fingerprint), probe: true);
    await settle();
  }

  group('probe replies', () {
    test(
      'contact_probe_answered: unicast announce:false with the real port',
      () async {
        await start();
        await pinFriend();
        await probe(friend);

        final r = replies();
        expect(r, hasLength(1));
        expect(r.single.announce, isFalse);
        expect(r.single.info.deviceId, me.id);
        expect(r.single.info.fingerprint, me.fp);
        expect(r.single.info.port, kDefaultPort);
        expect(bus.unicasts.single.toPort, kDefaultPort);
        expect(
          bus.multicasts.where((m) => identical(m.from, rx.transport)),
          isEmpty,
          reason: 'the answer is not broadcast',
        );
      },
    );

    test('probe_from_untrusted_fingerprint_unanswered', () async {
      await start();
      await pinFriend();
      await probe(stranger);
      expect(bus.unicasts, isEmpty);
      expect(registered, isEmpty);
    });

    test(
      'twin: a device that is NOT Contacts-only answers the same stranger',
      () async {
        contactsOnly = false;
        await start();
        await probe(stranger);
        expect(replies(), hasLength(1), reason: 'the harness can see replies');
      },
    );

    test('a probe without a fingerprint (legacy / plaintext device) is not '
        'answered', () async {
      await start();
      await probe(stranger, fingerprint: '');
      expect(bus.unicasts, isEmpty);
    });

    test('a contact\'s fingerprint is what counts, at both trust levels; '
        'blocked and unknown are strangers', () async {
      await start();
      await rx.trust.pin(
        deviceId: friend.id,
        fingerprint: friend.fp,
        alias: 'T',
        trust: PeerTrust.trusted,
      );
      await probe(friend);
      expect(replies(), hasLength(1), reason: 'trusted contact');

      bus.sent.clear();
      await rx.trust.block(enemy.fp);
      await probe(enemy);
      expect(bus.unicasts, isEmpty, reason: 'blocked is not a contact');

      await rx.trust.block(friend.fp);
      await probe(friend);
      expect(bus.unicasts, isEmpty, reason: 'a contact turned blocked');
    });

    test(
      'removing the contact makes the device invisible to it again',
      () async {
        await start();
        await pinFriend();
        await probe(friend);
        expect(replies(), hasLength(1));

        bus.sent.clear();
        await rx.trust.remove(friend.id);
        await probe(friend);
        expect(bus.unicasts, isEmpty);
      },
    );

    test(
      'toggling Contacts-only off and on takes effect on the next probe',
      () async {
        await start();
        await probe(stranger);
        expect(bus.unicasts, isEmpty);
        contactsOnly = false;
        await probe(stranger);
        expect(replies(), hasLength(1));
        bus.sent.clear();
        contactsOnly = true;
        await probe(stranger);
        expect(bus.unicasts, isEmpty);
      },
    );
  });

  group('announce:true with a real port (no registration for strangers)', () {
    test('a stranger gets neither POST /register nor a UDP reply', () async {
      await start(withRegistrar: true);
      await pinFriend();
      prober.announce(stranger.info());
      await settle();
      expect(registered, isEmpty);
      expect(bus.unicasts, isEmpty);
    });

    test('a contact is answered (register first)', () async {
      await start(withRegistrar: true);
      await pinFriend();
      prober.announce(friend.info());
      await settle();
      expect(registered, [friend.id]);
    });

    test('a contact is answered by UDP when there is no registrar', () async {
      await start();
      await pinFriend();
      prober.announce(friend.info());
      await settle();
      expect(replies(), hasLength(1));
      expect(replies().single.announce, isFalse);
    });

    test(
      'twin: when not Contacts-only the stranger is registered with',
      () async {
        contactsOnly = false;
        await start(withRegistrar: true);
        prober.announce(stranger.info());
        await settle();
        expect(registered, [stranger.id]);
      },
    );
  });

  // 4.2 rule 10: "sends no periodic announcement". SPEC-GAP: the announce at
  // start, the +1 s / +3 s schedule, announceNow() and refresh() are announces
  // too; the safer reading (no multicast datagram at all while Contacts-only)
  // is tested.
  group('no announcements', () {
    const schedule = [Duration(milliseconds: 10)];
    const periodic = Duration(milliseconds: 25);

    test('no_periodic_announce: nothing at start, on schedule, periodically, '
        'on announceNow() or refresh()', () async {
      await start(schedule: schedule, periodic: periodic);
      rx.discovery.announceNow();
      await rx.discovery.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await settle();

      expect(rx.discovery.announcesSent, 0);
      expect(bus.multicasts, isEmpty);
      expect(prober.received, isEmpty);
    });

    test(
      'twin: the same configuration announces when not Contacts-only',
      () async {
        contactsOnly = false;
        await start(schedule: schedule, periodic: periodic);
        await eventually(
          () => rx.discovery.announcesSent >= 3,
          what: 'announces',
        );
        expect(prober.announces, isNotEmpty);
      },
    );

    test(
      'the flag is read at every tick: announcing stops and resumes',
      () async {
        contactsOnly = false;
        await start(schedule: schedule, periodic: periodic);
        await eventually(
          () => rx.discovery.announcesSent >= 2,
          what: 'announces',
        );

        contactsOnly = true;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        final frozen = rx.discovery.announcesSent;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(
          rx.discovery.announcesSent,
          frozen,
          reason: 'silent while Contacts-only',
        );

        contactsOnly = false;
        await eventually(
          () => rx.discovery.announcesSent > frozen,
          what: 'announcing resumes',
        );
      },
    );
  });
}
