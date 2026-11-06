// Send-only probes (LSP-1 4.2 rule 8): a device with no listener (Receive mode
// Off) multicasts announce:true with port 0, is never listed or registered
// with, and still learns who is around. In-memory bus, no sockets.
import 'dart:async';

import 'package:libreshare_core/src/discovery/announce_codec.dart';
import 'package:libreshare_core/src/discovery/multicast_discovery.dart';
import 'package:libreshare_core/src/discovery/network_interfaces.dart';
import 'package:libreshare_core/src/discovery/peer_registry.dart';
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:libreshare_core/src/model/device.dart';
import 'package:test/test.dart';

const _hour = Duration(hours: 1);

class _NoIfaces implements NetworkInterfaceProvider {
  @override
  Future<List<LocalInterface>> list() async => const [];
}

class _Node {
  _Node(
    InMemoryMulticastBus bus,
    this.id, {
    required String address,
    this._port = 53318,
    bool probes = true,
  }) : transport = bus.createTransport(address: address),
       registry = PeerRegistry(selfDeviceId: id) {
    discovery = MulticastDiscovery(
      selfInfo: () => DeviceInfo(
        deviceId: id,
        alias: 'dev-$id',
        platform: 'linux',
        port: _port,
      ),
      transport: transport,
      registry: registry,
      registrar: (peer, ip) async {
        registered.add('${peer.deviceId}@$ip');
        return true;
      },
      ifaces: _NoIfaces(),
      announceSchedule: const [],
      periodicInterval: _hour,
      interfacePoll: _hour,
      probes: probes,
    );
  }

  final String id;
  final InMemoryMulticastTransport transport;
  final PeerRegistry registry;
  late final MulticastDiscovery discovery;
  final List<String> registered = [];
  int _port;

  set port(int p) => _port = p;
  List<String> get peerIds => [for (final d in registry.current) d.id]..sort();
}

Future<void> settle() => pumpEventQueue(times: 50);

void main() {
  late InMemoryMulticastBus bus;
  final nodes = <_Node>[];

  _Node node(
    String id,
    String address, {
    int port = 53318,
    bool probes = true,
  }) {
    final n = _Node(bus, id, address: address, port: port, probes: probes);
    nodes.add(n);
    return n;
  }

  setUp(() => bus = InMemoryMulticastBus());
  tearDown(() async {
    for (final n in nodes) {
      await n.discovery.stop();
      n.registry.dispose();
    }
    nodes.clear();
  });

  test(
    'a device without a listener announces a probe, not a fake port',
    () async {
      final off = node('OFF', '10.0.0.2', port: 0);
      await off.discovery.start();
      await settle();

      expect(off.discovery.announcesSent, 1);
      final msg = decodeAnnounce(bus.multicasts.single.data, allowProbe: true)!;
      expect(msg.isProbe, isTrue);
      expect(msg.announce, isTrue);
      expect(msg.info.deviceId, 'OFF');
      // The strict decoder (no probe support) drops it, as a pre-probe peer would.
      expect(decodeAnnounce(bus.multicasts.single.data), isNull);
    },
  );

  test(
    'a receivable device answers a probe by unicast, without registering',
    () async {
      final a = node('A', '10.0.0.2');
      final off = node('OFF', '10.0.0.3', port: 0);
      await a.discovery.start();
      await off.discovery.start();
      await settle();

      // OFF learned A (from A's own start announcement and from the reply).
      expect(off.peerIds, ['A']);
      expect(off.registry.byId('A')!.info.port, 53318);
      // A never listed OFF and never tried to POST /register to it.
      expect(a.peerIds, isEmpty);
      expect(a.registered, isEmpty);
      // The reply is a unicast announce:false with A's real port.
      final replies = bus.unicasts.where((s) => s.from == a.transport).toList();
      expect(replies, hasLength(1));
      final reply = decodeAnnounce(replies.single.data)!;
      expect(reply.announce, isFalse);
      expect(reply.info.port, 53318);
      expect(replies.single.to!.address, '10.0.0.3');
      expect(a.discovery.repliesSent, 1);
    },
  );

  test('a device without a listener records others but answers nobody', () async {
    final a = node('A', '10.0.0.2');
    final off = node('OFF', '10.0.0.3', port: 0);
    await off.discovery.start();
    await a.discovery.start();
    await settle();
    final before = bus.unicasts.length;

    a.discovery.announceNow();
    await settle();

    expect(off.peerIds, ['A']);
    expect(
      off.registered,
      isEmpty,
      reason: 'OFF has no listener to register with',
    );
    expect(off.discovery.repliesSent, 0);
    // The only unicast on the bus is A answering OFF's probe, nothing from OFF.
    expect(bus.unicasts.where((s) => s.from == off.transport), isEmpty);
    expect(bus.unicasts.length, before);
  });

  test(
    'two devices without a listener see nobody and talk to nobody',
    () async {
      final x = node('X', '10.0.0.2', port: 0);
      final y = node('Y', '10.0.0.3', port: 0);
      await x.discovery.start();
      await y.discovery.start();
      await settle();

      expect(x.peerIds, isEmpty);
      expect(y.peerIds, isEmpty);
      expect(bus.unicasts, isEmpty);
      expect(x.registered, isEmpty);
      expect(y.registered, isEmpty);
    },
  );

  test(
    'turning the listener on turns the probe into a real announcement',
    () async {
      final a = node('A', '10.0.0.2');
      final b = node('B', '10.0.0.3', port: 0);
      await a.discovery.start();
      await b.discovery.start();
      await settle();
      expect(a.peerIds, isEmpty);

      b.port = 53319; // Receive mode On: listener bound
      b.discovery.announceNow();
      await settle();

      expect(a.peerIds, ['B']);
      expect(a.registry.byId('B')!.info.port, 53319);
      expect(a.registered, ['B@10.0.0.3'], reason: 'now A registers back');
    },
  );

  test(
    'default (probes off): no listener means silence, a probe is malformed',
    () async {
      final legacy = node('L', '10.0.0.2', port: 0, probes: false);
      final a = node('A', '10.0.0.3', probes: false);
      await legacy.discovery.start();
      await a.discovery.start();
      await settle();
      expect(legacy.discovery.announcesSent, 0);

      // A probe from a probe-capable peer is dropped by a legacy receiver.
      final p = node('P', '10.0.0.4', port: 0);
      await p.discovery.start();
      await settle();
      expect(a.discovery.malformedPackets, 1);
      expect(a.peerIds, isEmpty);
      expect(a.discovery.repliesSent, 0);
    },
  );

  test('a probe claiming announce:false is dropped', () async {
    final a = node('A', '10.0.0.2');
    await a.discovery.start();
    final rogue = bus.createTransport(address: '10.0.0.9');
    await rogue.start();
    final hostile =
        '{"proto":"libreshare","v":"1.0","deviceId":"EVIL",'
        '"alias":"evil","fingerprint":"","port":0,"announce":false}';
    rogue.sendMulticast(hostile.codeUnits);
    await settle();
    expect(a.peerIds, isEmpty);
    expect(a.discovery.malformedPackets, 1);
    await rogue.stop();
  });

  test('probe floods are rate limited per source like any datagram', () async {
    final a = node('A', '10.0.0.2');
    await a.discovery.start();
    final off = node('OFF', '10.0.0.3', port: 0);
    await off.discovery.start();
    await settle();
    final base = a.discovery.repliesSent;

    for (var i = 0; i < 200; i++) {
      off.discovery.announceNow();
    }
    await settle();
    expect(a.discovery.rateLimitedPackets, greaterThan(150));
    expect(a.discovery.repliesSent - base, lessThanOrEqualTo(20));
  });

  test(
    'announceNow sends exactly one announcement and does nothing when stopped',
    () async {
      final a = node('A', '10.0.0.2');
      a.discovery.announceNow();
      expect(bus.sent, isEmpty);
      await a.discovery.start();
      final n = a.discovery.announcesSent;
      a.discovery.announceNow();
      expect(a.discovery.announcesSent, n + 1);
      await a.discovery.stop();
      a.discovery.announceNow();
      expect(a.discovery.announcesSent, n + 1);
    },
  );
}
