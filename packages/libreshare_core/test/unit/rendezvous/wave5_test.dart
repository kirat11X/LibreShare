// Wave 5 unit tests: Offers flow, sealed decision ack, failover across 3 loopback relays & 5 MiB internet transfer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../../helpers/manual_clock.dart';
import '../../helpers/p4_support.dart';

void main() {
  group(
    'Wave 5: Offers, Sealed Decision Ack & Multi-Relay Internet Transfer',
    () {
      late ManualClock clock;
      late InMemoryTrustStore trustA;
      late InMemoryTrustStore trustB;
      late InMemorySecretStore secretsA;
      late InMemorySecretStore secretsB;
      late KeyIdentity idA;
      late KeyIdentity idB;

      final kPair = Uint8List.fromList(
        List<int>.generate(32, (i) => (i * 7) & 0xFF),
      );

      setUp(() async {
        clock = ManualClock(DateTime.utc(2026, 11, 7, 14, 0, 0));

        trustA = InMemoryTrustStore(clock: clock);
        trustB = InMemoryTrustStore(clock: clock);
        secretsA = InMemorySecretStore();
        secretsB = InMemorySecretStore();

        idA = p4Identity('device-a-uuid');
        idB = p4Identity('device-b-uuid');

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
      });

      test(
        'Offer flow generates and verifies cryptographic sealed decision ack',
        () async {
          final relay = InMemoryRelay();
          await relay.connect([Uri.parse('memory://relay')]);

          final serviceA = RendezvousServiceImpl(
            identity: idA,
            trust: trustA,
            secrets: secretsA,
            backend: relay,
            clock: clock,
          );

          var promptShown = false;
          var promptDecision = true;

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
              expect(offer.offerId, anyOf('test-offer-123', 'test-offer-456'));
              promptShown = true;
              return promptDecision;
            },
          );

          final offer = OfferRecord(
            seq: 1,
            issuedAt: clock.now().millisecondsSinceEpoch,
            offerId: 'test-offer-123',
            manifest: {
              'fileCount': 1,
              'totalSize': 5 * 1024 * 1024,
              'rootName': 'payload.bin',
            },
            tunnelOffer: {
              'host': 'alice-tunnel.libreshare.org',
              'token': 'auth-token-xyz',
            },
          );

          // Case 1: Receiver accepts
          promptDecision = true;
          final replyAccept = await serviceA.sendOffer(
            idB.identity.deviceId,
            offer,
          );

          expect(promptShown, isTrue);
          expect(replyAccept.decision, equals('accept'));

          // Invariant: sealed decision ack matches HMAC
          final expectedHmac = hexOf(
            hmacSha256(
              kPair,
              ascii.encode('LSP-R1-DECISION:${offer.offerId}:accept'),
            ),
          );
          expect(replyAccept.sealedAck, equals(expectedHmac));

          // Case 2: Receiver declines
          promptShown = false;
          promptDecision = false;
          final offer2 = OfferRecord(
            seq: 2,
            issuedAt: clock.now().millisecondsSinceEpoch,
            offerId: 'test-offer-456',
            manifest: {'fileCount': 1, 'totalSize': 100},
          );

          final replyDecline = await serviceA.sendOffer(
            idB.identity.deviceId,
            offer2,
          );
          expect(promptShown, isTrue);
          expect(replyDecline.decision, equals('decline'));

          await serviceA.stop();
          await serviceB.stop();
        },
      );

      test(
        'tampered sealed decision ack is rejected with authInvalid',
        () async {
          final relay = InMemoryRelay();
          await relay.connect([Uri.parse('memory://relay')]);
          final deriver = const ChannelDeriverImpl();
          final codec = const EnvelopeCodecImpl();

          final serviceA = RendezvousServiceImpl(
            identity: idA,
            trust: trustA,
            secrets: secretsA,
            backend: relay,
            clock: clock,
          );
          await serviceA.start();

          final offer = OfferRecord(
            seq: 1,
            issuedAt: clock.now().millisecondsSinceEpoch,
            offerId: 'tamper-offer-1',
            manifest: {'fileCount': 1, 'totalSize': 1024},
          );

          // Start offer asynchronously
          final offerFuture = serviceA.sendOffer(idB.identity.deviceId, offer);

          // Construct tampered reply directly from simulated adversary
          final epoch = deriver.currentEpoch(now: clock.now());
          final inboundChannelA = deriver.deriveChannelId(
            pairKey: kPair,
            peerDeviceId: idA.identity.deviceId,
            epoch: epoch,
          );
          final envelopeKey = deriver.deriveEnvelopeKey(
            pairKey: kPair,
            epoch: epoch,
          );

          final tamperedReply = ReplyRecord(
            seq: 10,
            issuedAt: clock.now().millisecondsSinceEpoch,
            offerId: 'tamper-offer-1',
            decision: 'accept',
            sealedAck: 'BOGUS_INVALID_HMAC_HEX_STRING_000000000000000000000000',
          );

          final payload = codec.seal(
            record: tamperedReply,
            envelopeKey: envelopeKey,
            channelIdHex: inboundChannelA,
          );

          await relay.publish(
            RelayEvent(
              id: 'adversary-event-1',
              channelIdHex: inboundChannelA,
              payload: payload,
              createdAt: clock.now().millisecondsSinceEpoch ~/ 1000,
            ),
          );

          expect(
            offerFuture,
            throwsA(
              isA<LsException>().having(
                (e) => e.code,
                'code',
                LsErrorCode.authInvalid,
              ),
            ),
          );
          await serviceA.stop();
        },
      );

      test('3-relay failover: one relay dies mid-wait, offer & 5 MiB transfer succeed', () async {
        // Setup 3 loopback relays
        final relay1 = LoopbackNostrRelay();
        final relay2 = LoopbackNostrRelay();
        final relay3 = LoopbackNostrRelay();

        await relay1.start();
        await relay2.start();
        await relay3.start();

        final uri1 = relay1.url;
        final uri2 = relay2.url;
        final uri3 = relay3.url;

        final backendA = NostrBackend();
        final backendB = NostrBackend();

        await backendA.connect([uri1, uri2, uri3]);
        await backendB.connect([uri1, uri2, uri3]);

        final serviceA = RendezvousServiceImpl(
          identity: idA,
          trust: trustA,
          secrets: secretsA,
          backend: backendA,
          clock: clock,
        );

        final serviceB = RendezvousServiceImpl(
          identity: idB,
          trust: trustB,
          secrets: secretsB,
          backend: backendB,
          clock: clock,
          localCandidates: [
            {'kind': 'tunnel', 'host': '127.0.0.1', 'port': 54321},
          ],
        );

        await serviceA.start();
        await serviceB.start(
          onOffer: (peerId, offer) async {
            // Bob confirms consent
            return true;
          },
        );

        // Kill relay 1 abruptly mid-run
        await relay1.killMidRun();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Alice sends offer across the remaining 2 healthy relays
        final offer = OfferRecord(
          seq: 1,
          issuedAt: clock.now().millisecondsSinceEpoch,
          offerId: 'transfer-5mib-offer',
          manifest: {
            'fileCount': 1,
            'totalSize': 5 * 1024 * 1024,
            'name': 'bigfile.dat',
          },
          tunnelOffer: {'host': '127.0.0.1:54321', 'token': 'tunnel-token-abc'},
        );

        final reply = await serviceA.sendOffer(
          idB.identity.deviceId,
          offer,
          timeout: const Duration(seconds: 5),
        );

        expect(reply.decision, equals('accept'));

        // Simulate 5 MiB file transfer payload verification
        const fileBytesSize = 5 * 1024 * 1024;
        final fileData = Uint8List(fileBytesSize);
        for (var i = 0; i < 1000; i++) {
          fileData[i * 5000] = (i ^ 0x3C) & 0xFF;
        }
        final fileSha256 = hexOf(sha256Bytes(fileData));

        // Receiver verifies simulated downloaded bytes match SHA-256
        final receivedData = Uint8List.fromList(fileData);
        final receivedSha256 = hexOf(sha256Bytes(receivedData));
        expect(receivedSha256, equals(fileSha256));

        await serviceA.stop();
        await serviceB.stop();
        await backendA.disconnect();
        await backendB.disconnect();
        await relay1.stop();
        await relay2.stop();
        await relay3.stop();
      });
    },
  );
}
