// Wave 4 unit tests: PresenceCache, RendezvousServiceImpl, ReceiveGate hook & replay/forged guards.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../../helpers/manual_clock.dart';
import '../../helpers/p4_support.dart';

void main() {
  group('Wave 4: Presence, PresenceCache & ReceiveGate Hook', () {
    late ManualClock clock;
    late InMemoryRelay relay;
    late InMemoryTrustStore trustA;
    late InMemoryTrustStore trustB;
    late InMemorySecretStore secretsA;
    late InMemorySecretStore secretsB;
    late KeyIdentity idA;
    late KeyIdentity idB;
    late RendezvousServiceImpl serviceA;
    late RendezvousServiceImpl serviceB;

    final kPair = Uint8List.fromList(List<int>.generate(32, (i) => i ^ 0x5A));

    setUp(() async {
      clock = ManualClock(DateTime.utc(2026, 11, 7, 12, 0, 0));
      relay = InMemoryRelay();
      await relay.connect([Uri.parse("memory://local")]);

      trustA = InMemoryTrustStore(clock: clock);
      trustB = InMemoryTrustStore(clock: clock);
      secretsA = InMemorySecretStore();
      secretsB = InMemorySecretStore();

      idA = p4Identity('device-a-uuid');
      idB = p4Identity('device-b-uuid');

      // Setup paired state
      await trustA.pin(
        deviceId: idB.identity.deviceId,
        fingerprint: idB.identity.fingerprint,
        alias: 'Bob',
        trust: PeerTrust.trusted,
      );
      await trustA.setPairKey(idB.identity.deviceId, true);
      await secretsA.put('kpair/${idB.identity.deviceId}', kPair);

      await trustB.pin(
        deviceId: idA.identity.deviceId,
        fingerprint: idA.identity.fingerprint,
        alias: 'Alice',
        trust: PeerTrust.trusted,
      );
      await trustB.setPairKey(idA.identity.deviceId, true);
      await secretsB.put('kpair/${idA.identity.deviceId}', kPair);

      serviceA = RendezvousServiceImpl(
        identity: idA,
        trust: trustA,
        secrets: secretsA,
        backend: relay,
        clock: clock,
        announcePolicy: AnnouncePolicy.none,
      );

      serviceB = RendezvousServiceImpl(
        identity: idB,
        trust: trustB,
        secrets: secretsB,
        backend: relay,
        clock: clock,
        announcePolicy: AnnouncePolicy.none,
        localCandidates: [
          {'kind': 'tunnel', 'host': 'bob-tunnel.example.org', 'port': 443},
        ],
      );
    });

    tearDown(() async {
      await serviceA.stop();
      await serviceB.stop();
    });

    test('Alice sees Bob online <= 3 s when Bob announces presence', () async {
      await serviceA.start();

      // Bob starts with AnnouncePolicy.periodic (Everyone/Active receive)
      serviceB.announcePolicy = AnnouncePolicy.periodic;
      await serviceB.start();

      // Await presence event delivery on Alice
      final presenceEvent = await serviceA.presenceEvents.first.timeout(
        const Duration(seconds: 3),
      );

      expect(presenceEvent.key, equals(idB.identity.deviceId));
      expect(presenceEvent.value.candidates, hasLength(1));

      // Alice's PresenceCache marks Bob online
      expect(serviceA.presenceCache.isOnline(idB.identity.deviceId), isTrue);
      final peerPresence = serviceA.presenceCache.get(idB.identity.deviceId);
      expect(peerPresence, isNotNull);
      expect(peerPresence!.candidates, hasLength(1));
      expect(peerPresence.candidates.first.kind, equals(CandidateKind.tunnel));
      expect(
        peerPresence.candidates.first.host,
        equals('bob-tunnel.example.org'),
      );
    });

    test('receive_off_publishes_nothing_test: Receive Off publishes zero presence events', () async {
      await serviceA.start();

      // Bob has AnnouncePolicy.none (Receive mode Off)
      serviceB.announcePolicy = AnnouncePolicy.none;
      await serviceB.start();
      await serviceB.broadcastPresence();

      // Assert relay received zero published envelopes
      expect(relay.publishedCount, equals(0));

      // Alice's presence cache remains empty
      expect(serviceA.presenceCache.isOnline(idB.identity.deviceId), isFalse);
    });

    test('ReceiveGate hook dynamically enables presence when Receive mode turns on', () async {
      await serviceA.start();

      // Bob starts with Receive Off
      await serviceB.start();
      expect(relay.publishedCount, equals(0));

      // User turns on Receive mode -> ReceiveGate invokes setAnnounce(periodic)
      serviceB.setAnnounce(AnnouncePolicy.periodic);

      // Presence should be immediately published
      await Future<void>.delayed(Duration.zero);
      expect(relay.publishedCount, greaterThan(0));
      expect(serviceA.presenceCache.isOnline(idB.identity.deviceId), isTrue);
    });

    test('replayed and forged envelopes are rejected', () async {
      await serviceA.start();

      final deriver = const ChannelDeriverImpl();
      final codec = const EnvelopeCodecImpl();
      final epoch = deriver.currentEpoch(now: clock.now());
      final channelId = deriver.deriveChannelId(
        pairKey: kPair,
        peerDeviceId: idA.identity.deviceId,
        epoch: epoch,
      );
      final envelopeKey = deriver.deriveEnvelopeKey(
        pairKey: kPair,
        epoch: epoch,
      );

      // 1. Valid record
      final record = PresenceRecord(
        seq: 1,
        issuedAt: clock.now().millisecondsSinceEpoch,
        candidates: [],
      );
      final payload = codec.seal(
        record: record,
        envelopeKey: envelopeKey,
        channelIdHex: channelId,
      );

      final event = RelayEvent(
        id: 'event-1',
        channelIdHex: channelId,
        payload: payload,
        createdAt: clock.now().millisecondsSinceEpoch ~/ 1000,
      );

      // Publish first time -> Alice accepts
      await relay.publish(event);
      await Future<void>.delayed(Duration.zero);
      expect(serviceA.presenceCache.isOnline(idB.identity.deviceId), isTrue);

      // 2. Replay the exact same envelope -> rejected by ReplayGuard
      var replayedDelivered = false;
      final sub = serviceA.presenceEvents.listen(
        (_) => replayedDelivered = true,
      );

      await relay.publish(event);
      await Future<void>.delayed(Duration.zero);

      expect(replayedDelivered, isFalse);
      await sub.cancel();

      // 3. Forged envelope with random key -> decryption fails, dropped safely
      final badKey = Uint8List(32)..fillRange(0, 32, 0xEE);
      final forgedPayload = codec.seal(
        record: record,
        envelopeKey: badKey,
        channelIdHex: channelId,
      );
      final forgedEvent = RelayEvent(
        id: 'event-forged',
        channelIdHex: channelId,
        payload: forgedPayload,
        createdAt: clock.now().millisecondsSinceEpoch ~/ 1000,
      );

      await relay.publish(forgedEvent);
      await Future<void>.delayed(Duration.zero);
      // No crashes, no new presence
      expect(serviceA.presenceCache.isOnline(idB.identity.deviceId), isTrue);
    });

    test('presence expires when clock advances past TTL', () async {
      await serviceA.start();
      serviceB.announcePolicy = AnnouncePolicy.periodic;
      await serviceB.start();

      await serviceA.presenceEvents.first;
      expect(serviceA.presenceCache.isOnline(idB.identity.deviceId), isTrue);

      // Advance clock past 5-minute TTL
      await clock.advance(const Duration(minutes: 6));

      expect(serviceA.presenceCache.isOnline(idB.identity.deviceId), isFalse);
      expect(serviceA.presenceCache.onlinePeers, isEmpty);
    });

    test('revokePairing unsets pair key and evicts presence', () async {
      await serviceA.start();
      serviceB.announcePolicy = AnnouncePolicy.periodic;
      await serviceB.start();

      await serviceA.presenceEvents.first;
      expect(serviceA.presenceCache.isOnline(idB.identity.deviceId), isTrue);

      // Alice revokes pairing with Bob
      await serviceA.revokePairing(idB.identity.deviceId);

      // Invariants: pair key deleted, pair flag in trust store false, cache evicted
      expect(await secretsA.get('kpair/${idB.identity.deviceId}'), isNull);
      final contact = trustA.contacts.firstWhere(
        (c) => c.deviceId == idB.identity.deviceId,
      );
      expect(contact.hasPairKey, isFalse);
      expect(serviceA.presenceCache.isOnline(idB.identity.deviceId), isFalse);
    });
  });
}
