// Real-socket check of RawMulticastTransport (and one end-to-end discovery on
// top of it). Multicast is not available everywhere (sandboxes, some CI
// containers, hosts without a multicast-capable interface), so the test first
// probes the host once and SKIPS with a reason instead of failing.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:libreshare_core/src/discovery/announce_codec.dart';
import 'package:libreshare_core/src/discovery/device_discovery.dart';
import 'package:libreshare_core/src/discovery/multicast_discovery.dart';
import 'package:libreshare_core/src/discovery/multicast_transport.dart';
import 'package:libreshare_core/src/discovery/peer_registry.dart';
import 'package:libreshare_core/src/model/device.dart';
import 'package:test/test.dart';

/// Not the production port, so a running LibreShare on the dev box is not
/// disturbed (and does not disturb the test).
const int _testPort = 53390;

String? _skipReason;

/// Sends [payload] from [a] every 100 ms until [b] hears it or [within] runs
/// out. Returns the packet, or null.
Future<MulticastPacket?> _exchange(
  RawMulticastTransport a,
  RawMulticastTransport b,
  List<int> payload, {
  Duration within = const Duration(seconds: 3),
}) async {
  final got = Completer<MulticastPacket>();
  final sub = b.packets.listen((p) {
    if (!got.isCompleted &&
        utf8.decode(p.data, allowMalformed: true) == utf8.decode(payload)) {
      got.complete(p);
    }
  });
  final timer = Timer.periodic(
    const Duration(milliseconds: 100),
    (_) => a.sendMulticast(payload),
  );
  try {
    a.sendMulticast(payload);
    return await got.future.timeout(within);
  } on TimeoutException {
    return null;
  } finally {
    timer.cancel();
    await sub.cancel();
  }
}

void main() {
  setUpAll(() async {
    final a = RawMulticastTransport(port: _testPort);
    final b = RawMulticastTransport(port: _testPort);
    try {
      await a.start();
      await b.start();
      final p = await _exchange(
        a,
        b,
        utf8.encode('probe'),
        within: const Duration(seconds: 2),
      );
      if (p == null) {
        _skipReason =
            'UDP multicast is not delivered on this host (no multicast-capable '
            'non-loopback IPv4 interface, or the sandbox/firewall blocks it)';
      }
    } on Object catch (e) {
      _skipReason =
          'cannot open/join the multicast socket on UDP $_testPort: $e';
    } finally {
      await a.stop();
      await b.stop();
    }
  });

  test(
    'two transports exchange a multicast packet and a unicast reply',
    () async {
      if (_skipReason != null) {
        markTestSkipped(_skipReason!);
        return;
      }
      final a = RawMulticastTransport(port: _testPort);
      final b = RawMulticastTransport(port: _testPort);
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      await a.start();
      await b.start();
      expect(a.boundPort, _testPort);

      final payload = utf8.encode(
        'hello-multicast-${DateTime.now().microsecondsSinceEpoch}',
      );
      final heard = await _exchange(a, b, payload);
      expect(heard, isNotNull, reason: 'multicast datagram reached the peer');
      expect(heard!.data, payload);
      expect(heard.port, _testPort, reason: 'sent from the listening socket');
      expect(
        heard.source.isLoopback || heard.source.rawAddress.length == 4,
        isTrue,
      );

      // Unicast back to the sender's endpoint. Both sockets share the port, so
      // the kernel may hand the datagram to either; at least one must get it.
      final reply = utf8.encode('unicast-reply');
      final received = <String>[];
      final subs = [
        a.packets.listen(
          (p) => received.add(utf8.decode(p.data, allowMalformed: true)),
        ),
        b.packets.listen(
          (p) => received.add(utf8.decode(p.data, allowMalformed: true)),
        ),
      ];
      b.sendUnicast(reply, heard.source, heard.port);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      for (final s in subs) {
        await s.cancel();
      }
      expect(received, contains('unicast-reply'));

      // rejoin is safe on a live socket and multicast still works afterwards.
      await b.rejoin();
      final again = await _exchange(a, b, utf8.encode('after-rejoin'));
      expect(again, isNotNull);
    },
  );

  test(
    'start/stop are idempotent and a stopped transport can restart',
    () async {
      if (_skipReason != null) {
        markTestSkipped(_skipReason!);
        return;
      }
      final a = RawMulticastTransport(port: _testPort);
      addTearDown(a.stop);
      await Future.wait([a.start(), a.start()]);
      await a.stop();
      await a.stop();
      a.sendMulticast([1, 2, 3]); // no-op while stopped
      await a.start();
      expect(a.boundPort, _testPort);
    },
  );

  test(
    'two MulticastDiscovery instances find each other over real multicast',
    () async {
      if (_skipReason != null) {
        markTestSkipped(_skipReason!);
        return;
      }
      DeviceInfo info(String id, int port) => DeviceInfo(
        deviceId: id,
        alias: 'itest-$id',
        platform: 'linux',
        port: port,
      );
      final registries = <PeerRegistry>[];
      final discoveries = <MulticastDiscovery>[];
      for (final (id, port) in [('itest-A', 53391), ('itest-B', 53392)]) {
        final reg = PeerRegistry(selfDeviceId: id);
        registries.add(reg);
        discoveries.add(
          MulticastDiscovery(
            selfInfo: () => info(id, port),
            transport: RawMulticastTransport(port: _testPort),
            registry: reg,
            // Short schedule: unicast replies between two sockets that share
            // one host and one port may be handed to the wrong socket, so
            // rely on repeated multicast announcements as well.
            announceSchedule: const [
              Duration(milliseconds: 150),
              Duration(milliseconds: 500),
            ],
            periodicInterval: const Duration(seconds: 1),
          ),
        );
      }
      addTearDown(() async {
        for (final d in discoveries) {
          await d.stop();
        }
        for (final r in registries) {
          r.dispose();
        }
      });
      final sw = Stopwatch()..start();
      for (final d in discoveries) {
        await d.start();
      }
      while (registries.any((r) => r.current.length != 1) &&
          sw.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(registries[0].byId('itest-B'), isNotNull);
      expect(registries[1].byId('itest-A'), isNotNull);
      expect(registries[0].byId('itest-B')!.source, DiscoverySource.multicast);
      expect(registries[0].byId('itest-B')!.info.port, 53392);
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      expect(
        decodeAnnounce(encodeAnnounce(info('x', 1), announce: true)),
        isNotNull,
      );
    },
  );
}
