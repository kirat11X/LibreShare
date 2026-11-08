// Wave 2 unit tests: BIP-340 Schnorr, NIP-01, NostrBackend, and LoopbackNostrRelay failover.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

void main() {
  group('Wave 2: BIP-340 Schnorr Signatures', () {
    test('signBip340 and verifyBip340 roundtrip produces valid signature', () {
      final sk = BigInt.from(123456789);
      final pk = getBip340PublicKey(sk);
      final msg = Uint8List.fromList(List.generate(32, (i) => i));

      final sig = signBip340(sk: sk, message: msg);
      expect(sig.length, equals(64));

      final isValid = verifyBip340(pubKeyBytes: pk, message: msg, sig: sig);
      expect(isValid, isTrue);
    });

    test('tampered message or signature fails verification', () {
      final sk = BigInt.from(42);
      final pk = getBip340PublicKey(sk);
      final msg = Uint8List.fromList(List.generate(32, (i) => 255 - i));

      final sig = signBip340(sk: sk, message: msg);

      // Tamper message
      final badMsg = Uint8List.fromList(msg);
      badMsg[0] ^= 0x01;
      expect(verifyBip340(pubKeyBytes: pk, message: badMsg, sig: sig), isFalse);

      // Tamper signature
      final badSig = Uint8List.fromList(sig);
      badSig[10] ^= 0x01;
      expect(verifyBip340(pubKeyBytes: pk, message: msg, sig: badSig), isFalse);

      // Wrong public key
      final wrongPk = getBip340PublicKey(BigInt.from(43));
      expect(
        verifyBip340(pubKeyBytes: wrongPk, message: msg, sig: sig),
        isFalse,
      );
    });
  });

  group('Wave 2: NIP-01 Event Serialization & Verification', () {
    test('NostrEvent createAndSign generates valid event ID and signature', () {
      final sk = BigInt.from(999);
      final tags = [
        [
          'p',
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ],
        ['expiration', '1799285100'],
      ];
      const content = 'test_rendezvous_content_payload';

      final event = NostrEvent.createAndSign(
        sk: sk,
        kind: 20059,
        tags: tags,
        content: content,
        createdAt: 1799284800,
      );

      expect(event.id.length, equals(64));
      expect(event.sig.length, equals(128));
      expect(event.verify(), isTrue);

      // Tampered event content fails verification
      final tamperedJson = event.toJson();
      tamperedJson['content'] = 'tampered_content';
      final tamperedEvent = NostrEvent.fromJson(tamperedJson);
      expect(tamperedEvent.verify(), isFalse);
    });
  });

  group('Wave 2: Multi-Relay Failover & Safety Clamp', () {
    late LoopbackNostrRelay relay1;
    late LoopbackNostrRelay relay2;
    late LoopbackNostrRelay relay3;
    late NostrBackend backend;

    setUp(() async {
      relay1 = LoopbackNostrRelay();
      relay2 = LoopbackNostrRelay();
      relay3 = LoopbackNostrRelay();

      await relay1.start();
      await relay2.start();
      await relay3.start();

      backend = NostrBackend();
    });

    tearDown(() async {
      await backend.close();
      await relay1.stop();
      await relay2.stop();
      await relay3.stop();
    });

    test(
      'multiplexes across 3 relays and survives 1 relay killed mid-run',
      () async {
        final statuses = <RendezvousStatus>[];
        backend.statusStream.listen(statuses.add);

        await backend.connect([relay1.url, relay2.url, relay3.url]);
        expect(backend.status, equals(RendezvousStatus.connected));

        const channel =
            'aaabbbccc000111222333444555666777888999aaabbbccc00011122233344455';
        final receivedEvents = <RelayEvent>[];
        backend.events.listen(receivedEvents.add);

        await backend.subscribe(channel);

        // Publish event 1: all 3 relays alive
        final sk = BigInt.from(100);
        final ev1Signed = NostrEvent.createAndSign(
          sk: sk,
          kind: 20059,
          tags: [
            ['p', channel.toLowerCase()],
            ['expiration', '${1000 + 300}'],
          ],
          content: base64Url.encode(utf8.encode('hello_relay')),
          createdAt: 1000,
        );

        final event1 = RelayEvent(
          id: ev1Signed.id,
          channelIdHex: channel,
          payload: utf8.encode('hello_relay'),
          createdAt: 1000,
          ttlSeconds: 300,
          pubkeyHex: ev1Signed.pubkey,
          sigHex: ev1Signed.sig,
        );

        await backend.publish(event1);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(receivedEvents.length, equals(1));
        expect(
          utf8.decode(receivedEvents.first.payload),
          equals('hello_relay'),
        );

        // Kill Relay 2 abruptly
        await relay2.killMidRun();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Status degrades gracefully to degraded
        expect(backend.status, equals(RendezvousStatus.degraded));

        // Publish event 2: remaining 2 relays deliver event cleanly
        final ev2Signed = NostrEvent.createAndSign(
          sk: sk,
          kind: 20059,
          tags: [
            ['p', channel.toLowerCase()],
            ['expiration', '${1001 + 300}'],
          ],
          content: base64Url.encode(utf8.encode('survived_failover')),
          createdAt: 1001,
        );

        final event2 = RelayEvent(
          id: ev2Signed.id,
          channelIdHex: channel,
          payload: utf8.encode('survived_failover'),
          createdAt: 1001,
          ttlSeconds: 300,
          pubkeyHex: ev2Signed.pubkey,
          sigHex: ev2Signed.sig,
        );

        await backend.publish(event2);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(receivedEvents.length, equals(2));
        expect(
          utf8.decode(receivedEvents[1].payload),
          equals('survived_failover'),
        );
      },
    );

    test('hostile relay injecting frame > 128 KiB is dropped safely without crashing', () async {
      await backend.connect([relay1.url]);
      expect(backend.status, equals(RendezvousStatus.connected));

      const channel = 'safety_clamp_channel';
      await backend.subscribe(channel);

      // Inject oversized frame from relay1
      relay1.injectOversizedFrame();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Client connection remains healthy and alive
      expect(backend.status, equals(RendezvousStatus.connected));
    });
  });
}
