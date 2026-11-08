// Unit tests for NtfyBackend and FakeNtfyServer (Increment 6 Wave 7).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libreshare_core/src/rendezvous/ntfy_backend.dart';
import 'package:libreshare_core/src/rendezvous/rendezvous_backend.dart';
import 'package:test/test.dart';

import 'fake_ntfy_server.dart';

void main() {
  group('NtfyBackend Tests', () {
    late FakeNtfyServer server;
    late NtfyBackend backendA;
    late NtfyBackend backendB;

    setUp(() async {
      server = await FakeNtfyServer.start();
      backendA = NtfyBackend(pollInterval: const Duration(milliseconds: 50));
      backendB = NtfyBackend(pollInterval: const Duration(milliseconds: 50));
    });

    tearDown(() async {
      backendA.dispose();
      backendB.dispose();
      await server.close();
    });

    test('connect transitions status to connected', () async {
      expect(backendA.status, equals(RendezvousStatus.disconnected));

      await backendA.connect([server.uri]);
      expect(backendA.status, equals(RendezvousStatus.connected));
    });

    test('connect sets degraded if endpoint returns server error', () async {
      server.setErrorMode(true);
      await backendA.connect([server.uri]);
      expect(backendA.status, equals(RendezvousStatus.degraded));
    });

    test('topicForChannel truncates to 32 characters with ls-rdv prefix', () {
      final topic = NtfyBackend.topicForChannel(
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
      expect(topic, equals('ls-rdv-0123456789abcdef0123456789abcdef'));
    });

    test(
      'publish and subscribe transfers RelayEvent across backends',
      () async {
        await backendA.connect([server.uri]);
        await backendB.connect([server.uri]);

        const channel = 'aabbccdd11223344aabbccdd11223344';
        final receivedEvents = <RelayEvent>[];
        final completer = Completer<void>();

        final sub = backendB.events.listen((ev) {
          receivedEvents.add(ev);
          if (!completer.isCompleted) completer.complete();
        });

        await backendB.subscribe(channel);

        final payloadBytes = Uint8List.fromList(
          utf8.encode('Hello Ntfy World!'),
        );
        final event = RelayEvent(
          id: 'event-ntfy-1',
          channelIdHex: channel,
          payload: payloadBytes,
          createdAt: 1730987654,
          ttlSeconds: 600,
          pubkeyHex: '1111222233334444',
          sigHex: '5555666677778888',
        );

        await backendA.publish(event);

        await completer.future.timeout(const Duration(seconds: 3));
        await sub.cancel();

        expect(receivedEvents, hasLength(1));
        expect(receivedEvents[0].id, equals('event-ntfy-1'));
        expect(receivedEvents[0].channelIdHex, equals(channel));
        expect(receivedEvents[0].payload, equals(payloadBytes));
        expect(receivedEvents[0].pubkeyHex, equals('1111222233334444'));
        expect(receivedEvents[0].sigHex, equals('5555666677778888'));
      },
    );

    test('deduplicates events across multiple poll cycles', () async {
      await backendA.connect([server.uri]);
      await backendB.connect([server.uri]);

      const channel = 'channel-dedup-test';
      final receivedEvents = <RelayEvent>[];

      final sub = backendB.events.listen((ev) {
        receivedEvents.add(ev);
      });

      await backendB.subscribe(channel);

      final event = RelayEvent(
        id: 'event-dedup-1',
        channelIdHex: channel,
        payload: Uint8List.fromList([1, 2, 3, 4]),
        createdAt: 1730987000,
      );

      await backendA.publish(event);

      // Wait multiple poll intervals (pollInterval = 50ms)
      await Future.delayed(const Duration(milliseconds: 250));
      await sub.cancel();

      expect(receivedEvents, hasLength(1));
      expect(receivedEvents[0].id, equals('event-dedup-1'));
    });

    test(
      'channel isolation ensures events do not leak to other channels',
      () async {
        await backendA.connect([server.uri]);
        await backendB.connect([server.uri]);

        const channelSubscribed = 'channel-target';
        const channelOther = 'channel-ignored';

        final receivedEvents = <RelayEvent>[];
        final sub = backendB.events.listen(receivedEvents.add);

        await backendB.subscribe(channelSubscribed);

        // Publish to different channel
        await backendA.publish(
          RelayEvent(
            id: 'other-event',
            channelIdHex: channelOther,
            payload: Uint8List.fromList([9, 9, 9]),
            createdAt: 1730987000,
          ),
        );

        await Future.delayed(const Duration(milliseconds: 150));
        await sub.cancel();

        expect(receivedEvents, isEmpty);
      },
    );

    test(
      'disconnect clears subscriptions and sets disconnected status',
      () async {
        await backendA.connect([server.uri]);
        expect(backendA.status, equals(RendezvousStatus.connected));

        await backendA.disconnect();
        expect(backendA.status, equals(RendezvousStatus.disconnected));
      },
    );
  });
}
