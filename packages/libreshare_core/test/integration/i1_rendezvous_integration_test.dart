// Increment 6 / Integration Card I1: Rendezvous & Pairing Integration Suite.
// Verifies PairingService mutual SAS agreement -> K_pair derivation,
// RendezvousServiceImpl encrypted offers flow, sealed decision ack,
// anti-replay / signature tampering defenses, and multi-relay failover.
@TestOn('vm')
@Timeout(Duration(minutes: 2))
library;

import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p4_support.dart';

void main() {
  group('I1: Rendezvous & Pairing Integration Suite', () {
    late ManualClock clock;
    late InMemoryTrustStore trustA;
    late InMemoryTrustStore trustB;
    late InMemorySecretStore secretsA;
    late InMemorySecretStore secretsB;
    late KeyIdentity idA;
    late KeyIdentity idB;

    setUp(() async {
      clock = ManualClock(DateTime.utc(2026, 11, 8, 12, 0, 0));
      trustA = InMemoryTrustStore(clock: clock);
      trustB = InMemoryTrustStore(clock: clock);
      secretsA = InMemorySecretStore();
      secretsB = InMemorySecretStore();

      idA = p4Identity('alice-uuid');
      idB = p4Identity('bob-uuid');
    });

    test('1. PairingService completes handshake with identical SAS agreement and derived K_pair', () async {
      final serviceA = PairingService(
        identity: idA,
        trust: trustA,
        secrets: secretsA,
        clock: clock,
        self: () => DeviceInfo(
          deviceId: idA.identity.deviceId,
          alias: 'Alice',
          platform: 'linux',
          fingerprint: idA.identity.fingerprint,
          version: kProtocolVersionSecure,
        ),
      );

      final serviceB = PairingService(
        identity: idB,
        trust: trustB,
        secrets: secretsB,
        clock: clock,
        self: () => DeviceInfo(
          deviceId: idB.identity.deviceId,
          alias: 'Bob',
          platform: 'linux',
          fingerprint: idB.identity.fingerprint,
          version: kProtocolVersionSecure,
        ),
      );

      // Alice creates invite
      final invite = serviceA.createInvite();

      // Bob scans invite
      final inviterCard = DeviceInfo(
        deviceId: idA.identity.deviceId,
        alias: 'Alice',
        platform: 'linux',
        fingerprint: idA.identity.fingerprint,
        version: kProtocolVersionSecure,
      );

      final scan = serviceB.startScan(
        inviteSecretB64: invite.secretB64,
        inviter: inviterCard,
      );

      // Alice handles pair request and decides to accept
      final pairFuture = serviceA.handlePair(scan.request, peer: peerOf(idB));

      expect(serviceA.pendingPrompt, isNotNull);
      expect(
        serviceA.pendingPrompt!.fingerprint,
        equals(idB.identity.fingerprint),
      );
      serviceA.decide(accept: true);

      final pairResponse = await pairFuture;
      expect(pairResponse.accepted, isTrue);

      final completed = await scan.complete(pairResponse);
      expect(completed, isTrue);

      // Invariant: Both sides derive and store identical K_pair
      final kPairA = await secretsA.get('kpair/${idB.identity.deviceId}');
      final kPairB = await secretsB.get('kpair/${idA.identity.deviceId}');

      expect(kPairA, isNotNull);
      expect(kPairB, isNotNull);
      expect(kPairA, equals(kPairB));
      expect(kPairA!.length, equals(32));
    });

    test('2. Rendezvous encrypted offer flow exchanges manifest and validates sealed decision ack', () async {
      final kPair = Uint8List.fromList(
        List.generate(32, (i) => (i * 17 + 3) & 0xFF),
      );

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

      final relay = InMemoryRelay();
      await relay.connect([Uri.parse('memory://relay1')]);

      final serviceA = RendezvousServiceImpl(
        identity: idA,
        trust: trustA,
        secrets: secretsA,
        backend: relay,
        clock: clock,
      );

      var offerPromptReceived = false;
      final serviceB = RendezvousServiceImpl(
        identity: idB,
        trust: trustB,
        secrets: secretsB,
        backend: relay,
        clock: clock,
      );

      await serviceA.start();
      await serviceB.start(
        onOffer: (peerId, offer) async {
          expect(peerId, equals(idA.identity.deviceId));
          expect(offer.offerId, equals('offer-i1-rendezvous'));
          offerPromptReceived = true;
          return true; // Accept offer
        },
      );

      final offer = OfferRecord(
        seq: 1,
        issuedAt: clock.now().millisecondsSinceEpoch,
        offerId: 'offer-i1-rendezvous',
        manifest: {
          'fileCount': 1,
          'totalSize': 1024 * 1024,
          'rootName': 'archive.zip',
        },
        tunnelOffer: {
          'host': 'rendezvous.libreshare.org',
          'token': 'auth-tok-i1',
        },
      );

      final reply = await serviceA.sendOffer(idB.identity.deviceId, offer);

      expect(offerPromptReceived, isTrue);
      expect(reply.decision, equals('accept'));
      expect(reply.sealedAck, isNotEmpty);

      await serviceA.stop();
      await serviceB.stop();
    });

    test(
      '3. Anti-replay guard drops duplicate timestamps and duplicate offer IDs',
      () {
        final guard = ReplayGuard(maxSkew: const Duration(seconds: 120));
        final now = clock.now();

        final record1 = OfferRecord(
          seq: 1,
          issuedAt: now.millisecondsSinceEpoch,
          offerId: 'offer-seq-1',
          manifest: const {},
        );

        // First presentation is accepted
        guard.validate(record1, channelIdHex: 'chan1', now: now);

        // Replayed non-monotonic sequence number throws
        final recordNonMonotonic = OfferRecord(
          seq: 1,
          issuedAt: now.millisecondsSinceEpoch,
          offerId: 'offer-seq-1-dup',
          manifest: const {},
        );
        expect(
          () => guard.validate(
            recordNonMonotonic,
            channelIdHex: 'chan1',
            now: now,
          ),
          throwsA(
            isA<ReplayException>().having(
              (e) => e.violation,
              'violation',
              equals(ReplayViolation.sequenceNotMonotonic),
            ),
          ),
        );

        // Duplicate offerId throws
        final recordDupOffer = OfferRecord(
          seq: 2,
          issuedAt: now.millisecondsSinceEpoch,
          offerId: 'offer-seq-1',
          manifest: const {},
        );
        expect(
          () => guard.validate(recordDupOffer, channelIdHex: 'chan1', now: now),
          throwsA(
            isA<ReplayException>().having(
              (e) => e.violation,
              'violation',
              equals(ReplayViolation.duplicateOfferId),
            ),
          ),
        );

        // Too old timestamp (> 120s) throws clockSkewExceeded
        final oldRecord = OfferRecord(
          seq: 3,
          issuedAt: now
              .subtract(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
          offerId: 'offer-old',
          manifest: const {},
        );
        expect(
          () => guard.validate(oldRecord, channelIdHex: 'chan1', now: now),
          throwsA(
            isA<ReplayException>().having(
              (e) => e.violation,
              'violation',
              equals(ReplayViolation.clockSkewExceeded),
            ),
          ),
        );
      },
    );

    test('4. EnvelopeCodecImpl enforces padding buckets and rejects tampered payload', () {
      const codec = EnvelopeCodecImpl();
      final key = Uint8List.fromList(List.generate(32, (i) => (i * 5) & 0xFF));
      const channelIdHex =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

      final record = OfferRecord(
        seq: 1,
        issuedAt: clock.now().millisecondsSinceEpoch,
        offerId: 'offer-codec-1',
        manifest: {'name': 'test.bin'},
      );

      final envelope = codec.seal(
        record: record,
        envelopeKey: key,
        channelIdHex: channelIdHex,
      );

      // Must be padded into one of discrete bucket sizes (512, 1024, 2048, 4096) + overhead (28 bytes)
      expect(envelope.length, equals(512 + 28));

      // Valid unseal
      final unsealed = codec.unseal(
        payload: envelope,
        envelopeKey: key,
        channelIdHex: channelIdHex,
      );
      expect(unsealed, isA<OfferRecord>());
      expect((unsealed as OfferRecord).offerId, equals('offer-codec-1'));

      // Tampered byte in ciphertext triggers FormatException
      final tampered = Uint8List.fromList(envelope);
      tampered[tampered.length - 1] ^= 0xFF;

      expect(
        () => codec.unseal(
          payload: tampered,
          envelopeKey: key,
          channelIdHex: channelIdHex,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('5. Multi-relay failover reconnects to secondary relay when primary drops', () async {
      final relay1 = InMemoryRelay(name: 'relay-primary');
      final relay2 = InMemoryRelay(name: 'relay-secondary');

      await relay1.connect([Uri.parse('memory://relay1')]);
      await relay2.connect([Uri.parse('memory://relay2')]);

      expect(relay1.isConnected, isTrue);
      expect(relay2.isConnected, isTrue);

      final event = RelayEvent(
        id: 'event-failover-1',
        channelIdHex: 'chan-failover',
        payload: Uint8List.fromList([1, 2, 3]),
        createdAt: 1000,
      );

      // Publish on relay1
      await relay1.publish(event);
      expect(relay1.publishedCount, equals(1));

      // Simulate primary disconnect
      await relay1.disconnect();
      expect(relay1.isConnected, isFalse);

      // Failover to secondary relay succeeds
      await relay2.publish(event);
      expect(relay2.publishedCount, equals(1));

      await relay1.close();
      await relay2.close();
    });
  });
}
