// Wave 1 unit tests: ChannelDeriver, EnvelopeCodec, ReplayGuard, and InMemoryRelay.
library;

import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

void main() {
  group('Wave 1: ChannelDeriver', () {
    const deriver = ChannelDeriverImpl();
    final testPairKey = Uint8List.fromList(List.generate(32, (i) => i + 1));
    const testDeviceId = 'device_test_12345';

    test('currentEpoch derives consistent 24h UTC boundaries', () {
      final t1 = DateTime.utc(2026, 11, 7, 23, 59, 59);
      final t2 = DateTime.utc(2026, 11, 8, 0, 0, 0);

      final e1 = deriver.currentEpoch(now: t1);
      final e2 = deriver.currentEpoch(now: t2);

      expect(e2, equals(e1 + 1));
    });

    test(
      'deriveChannelId and deriveEnvelopeKey are deterministic and distinct',
      () {
        final chan1 = deriver.deriveChannelId(
          pairKey: testPairKey,
          peerDeviceId: testDeviceId,
          epoch: 20000,
        );
        final chan2 = deriver.deriveChannelId(
          pairKey: testPairKey,
          peerDeviceId: testDeviceId,
          epoch: 20000,
        );
        final chanNextEpoch = deriver.deriveChannelId(
          pairKey: testPairKey,
          peerDeviceId: testDeviceId,
          epoch: 20001,
        );

        expect(chan1, equals(chan2));
        expect(chan1.length, equals(64)); // 32-byte HMAC in hex
        expect(chan1, isNot(equals(chanNextEpoch)));

        final key1 = deriver.deriveEnvelopeKey(
          pairKey: testPairKey,
          epoch: 20000,
        );
        final key2 = deriver.deriveEnvelopeKey(
          pairKey: testPairKey,
          epoch: 20000,
        );
        final keyNext = deriver.deriveEnvelopeKey(
          pairKey: testPairKey,
          epoch: 20001,
        );

        expect(key1, equals(key2));
        expect(key1.length, equals(32));
        expect(key1, isNot(equals(keyNext)));
      },
    );

    test('rejects pairKey with invalid length', () {
      expect(
        () => deriver.deriveChannelId(
          pairKey: Uint8List(16),
          peerDeviceId: testDeviceId,
        ),
        throwsArgumentError,
      );
    });
  });

  group('Wave 1: EnvelopeCodec & Length Bucketing', () {
    const codec = EnvelopeCodecImpl();
    final key = Uint8List.fromList(List.generate(32, (i) => (i * 7) % 256));
    const channelId =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    test('seals and unseals PresenceRecord with discrete length bucketing', () {
      const record = PresenceRecord(
        seq: 1,
        issuedAt: 1799284800000,
        ttl: 180,
        candidates: [
          {'kind': 'directIpv6', 'host': '2001:db8::1', 'port': 53330},
        ],
      );

      final sealed = codec.seal(
        record: record,
        envelopeKey: key,
        channelIdHex: channelId,
      );

      // Total sealed length = 12 (IV) + bucket + 16 (tag)
      // Small record fits in 512 bucket -> 512 + 28 = 540 bytes
      expect(sealed.length, equals(512 + 28));

      final unsealed = codec.unseal(
        payload: sealed,
        envelopeKey: key,
        channelIdHex: channelId,
      ) as PresenceRecord;

      expect(unsealed.seq, equals(1));
      expect(unsealed.ttl, equals(180));
      expect(unsealed.candidates.first['host'], equals('2001:db8::1'));
    });

    test('large OfferRecord scales to larger bucket boundary cleanly', () {
      // Create a manifest with multiple files to exceed 512 bucket
      final files = List.generate(
        15,
        (i) => {'name': 'file_$i.txt', 'size': 1024 * i, 'sha256': 'a' * 64},
      );
      final record = OfferRecord(
        seq: 5,
        issuedAt: 1799284810000,
        offerId: 'off_large_123',
        manifest: {'files': files},
      );

      final sealed = codec.seal(
        record: record,
        envelopeKey: key,
        channelIdHex: channelId,
      );

      // Verify sealed payload matches one of the standard bucket sizes + 28 overhead
      final ciphertextLen = sealed.length - 28;
      expect(kRendezvousBuckets, contains(ciphertextLen));

      final unsealed = codec.unseal(
        payload: sealed,
        envelopeKey: key,
        channelIdHex: channelId,
      ) as OfferRecord;

      expect(unsealed.offerId, equals('off_large_123'));
      expect((unsealed.manifest['files'] as List).length, equals(15));
    });

    test('tampered ciphertext fails decryption and authentication', () {
      const record = ProbeRecord(seq: 2, issuedAt: 1000, nonce: 'nonce123');
      final sealed = codec.seal(
        record: record,
        envelopeKey: key,
        channelIdHex: channelId,
      );

      // Tamper 1 bit in ciphertext
      final tampered = Uint8List.fromList(sealed);
      tampered[20] ^= 0x01;

      expect(
        () => codec.unseal(
          payload: tampered,
          envelopeKey: key,
          channelIdHex: channelId,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('wrong envelopeKey fails authentication tag check', () {
      const record = ProbeRecord(seq: 3, issuedAt: 1000, nonce: 'nonce123');
      final sealed = codec.seal(
        record: record,
        envelopeKey: key,
        channelIdHex: channelId,
      );

      final wrongKey = Uint8List.fromList(List.generate(32, (i) => i));

      expect(
        () => codec.unseal(
          payload: sealed,
          envelopeKey: wrongKey,
          channelIdHex: channelId,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('mismatched channelIdHex fails AAD binding verification', () {
      const record = ProbeRecord(seq: 4, issuedAt: 1000, nonce: 'nonce123');
      final sealed = codec.seal(
        record: record,
        envelopeKey: key,
        channelIdHex: channelId,
      );

      const wrongChannel =
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

      expect(
        () => codec.unseal(
          payload: sealed,
          envelopeKey: key,
          channelIdHex: wrongChannel,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Wave 1: ReplayGuard', () {
    late ReplayGuard guard;
    const chan = 'channel_a';
    final now = DateTime.utc(2026, 11, 7, 12, 0, 0);

    setUp(() {
      guard = ReplayGuard(maxSkew: const Duration(seconds: 120));
    });

    test('accepts strictly increasing sequence numbers', () {
      final r1 = PresenceRecord(seq: 1, issuedAt: now.millisecondsSinceEpoch);
      final r2 = PresenceRecord(
        seq: 2,
        issuedAt: now.millisecondsSinceEpoch + 100,
      );

      expect(
        () => guard.validate(r1, channelIdHex: chan, now: now),
        returnsNormally,
      );
      expect(
        () => guard.validate(r2, channelIdHex: chan, now: now),
        returnsNormally,
      );
    });

    test('rejects non-monotonic sequence numbers', () {
      final r1 = PresenceRecord(seq: 10, issuedAt: now.millisecondsSinceEpoch);
      guard.validate(r1, channelIdHex: chan, now: now);

      final rOlder = PresenceRecord(
        seq: 9,
        issuedAt: now.millisecondsSinceEpoch,
      );
      final rEqual = PresenceRecord(
        seq: 10,
        issuedAt: now.millisecondsSinceEpoch,
      );

      expect(
        () => guard.validate(rOlder, channelIdHex: chan, now: now),
        throwsA(
          isA<ReplayException>().having(
            (e) => e.violation,
            'violation',
            ReplayViolation.sequenceNotMonotonic,
          ),
        ),
      );

      expect(
        () => guard.validate(rEqual, channelIdHex: chan, now: now),
        throwsA(
          isA<ReplayException>().having(
            (e) => e.violation,
            'violation',
            ReplayViolation.sequenceNotMonotonic,
          ),
        ),
      );
    });

    test(
      'rejects messages with clock skew exceeding maximum allowable limit',
      () {
        final rPast = PresenceRecord(
          seq: 1,
          issuedAt: now.millisecondsSinceEpoch - 130 * 1000, // 130s skew
        );
        final rFuture = PresenceRecord(
          seq: 2,
          issuedAt: now.millisecondsSinceEpoch + 150 * 1000, // 150s skew
        );

        expect(
          () => guard.validate(rPast, channelIdHex: chan, now: now),
          throwsA(
            isA<ReplayException>().having(
              (e) => e.violation,
              'violation',
              ReplayViolation.clockSkewExceeded,
            ),
          ),
        );

        expect(
          () => guard.validate(rFuture, channelIdHex: chan, now: now),
          throwsA(
            isA<ReplayException>().having(
              (e) => e.violation,
              'violation',
              ReplayViolation.clockSkewExceeded,
            ),
          ),
        );
      },
    );

    test('rejects duplicate offerId across distinct messages', () {
      final off1 = OfferRecord(
        seq: 1,
        issuedAt: now.millisecondsSinceEpoch,
        offerId: 'offer_unique_1',
        manifest: {},
      );
      final offDuplicate = OfferRecord(
        seq: 2,
        issuedAt: now.millisecondsSinceEpoch + 50,
        offerId: 'offer_unique_1',
        manifest: {},
      );

      guard.validate(off1, channelIdHex: chan, now: now);
      expect(
        () => guard.validate(offDuplicate, channelIdHex: chan, now: now),
        throwsA(
          isA<ReplayException>().having(
            (e) => e.violation,
            'violation',
            ReplayViolation.duplicateOfferId,
          ),
        ),
      );
    });
  });

  group('Wave 1: InMemoryRelay', () {
    test(
      'routes events to subscribed channels and ignores unsubscribed',
      () async {
        final relay = InMemoryRelay();
        final statuses = <RendezvousStatus>[];
        relay.statusStream.listen(statuses.add);

        await relay.connect([Uri.parse('memory://relay')]);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(relay.isConnected, isTrue);
        expect(statuses, contains(RendezvousStatus.connected));

        final receivedEvents = <RelayEvent>[];
        relay.events.listen(receivedEvents.add);

        const chanA = 'chan_a_123';
        const chanB = 'chan_b_456';

        await relay.subscribe(chanA);

        final eventA = RelayEvent(
          id: 'id_a',
          channelIdHex: chanA,
          payload: Uint8List(32),
          createdAt: 1000,
        );
        final eventB = RelayEvent(
          id: 'id_b',
          channelIdHex: chanB,
          payload: Uint8List(32),
          createdAt: 1001,
        );

        await relay.publish(eventA);
        await relay.publish(eventB); // Not subscribed

        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(receivedEvents.length, equals(1));
        expect(receivedEvents.first.id, equals('id_a'));

        // Dropped channel test
        relay.droppedChannels.add(chanA);
        await relay.publish(eventA);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(receivedEvents.length, equals(1)); // Still 1, 2nd was dropped

        await relay.close();
      },
    );
  });
}
