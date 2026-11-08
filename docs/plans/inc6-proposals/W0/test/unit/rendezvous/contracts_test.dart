// Rendezvous Wave 0 contract tests: Record hierarchy and CandidateSource.
library;

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

void main() {
  group('Rendezvous Wave 0 Contracts & Records', () {
    test('PresenceRecord serializes and deserializes cleanly', () {
      const rec = PresenceRecord(
        seq: 10,
        issuedAt: 1799284800000,
        ttl: 120,
        candidates: [
          {'kind': 'directIpv6', 'host': '2001:db8::1', 'port': 53330},
        ],
        caps: ['rdv1', 'tls13'],
      );

      final json = rec.toJson();
      expect(json['type'], 'presence');
      expect(json['seq'], 10);
      expect(json['ttl'], 120);

      final parsed = RendezvousRecord.fromJson(json) as PresenceRecord;
      expect(parsed.type, 'presence');
      expect(parsed.seq, 10);
      expect(parsed.ttl, 120);
      expect(parsed.candidates.length, 1);
      expect(parsed.candidates.first['host'], '2001:db8::1');
      expect(parsed.caps, contains('rdv1'));
    });

    test('ProbeRecord serializes and deserializes cleanly', () {
      const rec = ProbeRecord(
        seq: 11,
        issuedAt: 1799284805000,
        nonce: 'test_probe_nonce_123',
      );

      final json = rec.toJson();
      expect(json['type'], 'probe');
      expect(json['nonce'], 'test_probe_nonce_123');

      final parsed = RendezvousRecord.fromJson(json) as ProbeRecord;
      expect(parsed.seq, 11);
      expect(parsed.nonce, 'test_probe_nonce_123');
    });

    test('OfferRecord and ReplyRecord serialize and deserialize cleanly', () {
      const offer = OfferRecord(
        seq: 12,
        issuedAt: 1799284810000,
        offerId: 'off_12345',
        manifest: {'sessionId': 's1', 'totalSize': 1024},
        tunnelOffer: {
          'provider': 'cloudflare',
          'url': 'https://tunnel.example.com',
        },
        candidates: [
          {'kind': 'mappedIpv4', 'host': '198.51.100.1', 'port': 53330},
        ],
      );

      final offerJson = offer.toJson();
      final parsedOffer = RendezvousRecord.fromJson(offerJson) as OfferRecord;
      expect(parsedOffer.offerId, 'off_12345');
      expect(parsedOffer.manifest['totalSize'], 1024);
      expect(parsedOffer.tunnelOffer?['provider'], 'cloudflare');

      const reply = ReplyRecord(
        seq: 13,
        issuedAt: 1799284812000,
        offerId: 'off_12345',
        decision: 'accept',
        sealedAck: 'sealed_ack_bytes',
      );

      final replyJson = reply.toJson();
      final parsedReply = RendezvousRecord.fromJson(replyJson) as ReplyRecord;
      expect(parsedReply.offerId, 'off_12345');
      expect(parsedReply.isAccepted, isTrue);
      expect(parsedReply.sealedAck, 'sealed_ack_bytes');
    });

    test(
      'RevokeRecord, PairHelloRecord and PairAcceptRecord roundtrip cleanly',
      () {
        final revoke = RevokeRecord(
          seq: 14,
          issuedAt: 1799284820000,
          revokedAt: 1799284820000,
        );
        final parsedRevoke =
            RendezvousRecord.fromJson(revoke.toJson()) as RevokeRecord;
        expect(parsedRevoke.revokedAt, 1799284820000);

        final hello = PairHelloRecord(
          seq: 1,
          issuedAt: 1000,
          scannerFingerprint: 'A' * 64,
          nonce: 'nonce1',
          mac: 'mac1',
        );
        final parsedHello =
            RendezvousRecord.fromJson(hello.toJson()) as PairHelloRecord;
        expect(parsedHello.scannerFingerprint, 'A' * 64);

        final accept = PairAcceptRecord(
          seq: 2,
          issuedAt: 1001,
          inviterFingerprint: 'B' * 64,
          nonce: 'nonce2',
          mac: 'mac2',
        );
        final parsedAccept =
            RendezvousRecord.fromJson(accept.toJson()) as PairAcceptRecord;
        expect(parsedAccept.inviterFingerprint, 'B' * 64);
      },
    );

    test('RendezvousCandidateSource extracts valid candidates from presence record', () {
      const source = RendezvousCandidateSource();
      const presence = PresenceRecord(
        seq: 1,
        issuedAt: 1000,
        candidates: [
          {'kind': 'directIpv6', 'host': '2001:db8::1', 'port': 53330},
          {'kind': 'mappedIpv4', 'host': '198.51.100.1', 'port': 53330},
          {'kind': 'tunnel', 'host': 'relay.example.com', 'port': 443},
          {'kind': 'invalid', 'host': '', 'port': -1}, // ignored
        ],
      );

      final candidates = source.candidatesFromPresence(
        presence: presence,
        peerFingerprint: 'F' * 64,
      );

      expect(candidates.length, 3);
      expect(candidates[0].host, '2001:db8::1');
      expect(candidates[0].port, 53330);
      expect(candidates[0].costHint, 15);

      expect(candidates[1].host, '198.51.100.1');
      expect(candidates[1].costHint, 25);

      expect(candidates[2].kind, CandidateKind.tunnel);
      expect(candidates[2].costHint, 100);
    });
  });
}
