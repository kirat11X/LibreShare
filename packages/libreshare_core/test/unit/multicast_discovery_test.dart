import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/src/clock.dart';
import 'package:libreshare_core/src/discovery/announce_codec.dart';
import 'package:libreshare_core/src/discovery/device_discovery.dart';
import 'package:libreshare_core/src/discovery/multicast_discovery.dart';
import 'package:libreshare_core/src/discovery/multicast_transport.dart';
import 'package:libreshare_core/src/discovery/network_interfaces.dart';
import 'package:libreshare_core/src/discovery/peer_registry.dart';
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:libreshare_core/src/model/device.dart';
import 'package:test/test.dart';

const _hour = Duration(hours: 1);
const _fpA = 'AA00000000000000000000000000000000000000000000000000000000000001';
const _fpB = 'BB00000000000000000000000000000000000000000000000000000000000002';

class FakeClock implements Clock {
  DateTime _now = DateTime.utc(2026, 11, 3, 12);
  @override
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

class FakeIfaces implements NetworkInterfaceProvider {
  FakeIfaces(this.items);
  List<LocalInterface> items;
  @override
  Future<List<LocalInterface>> list() async => List.of(items);
}

LocalInterface _iface(String name, String ip, [String kind = 'wifi']) =>
    LocalInterface(name: name, address: InternetAddress(ip), kind: kind);

DeviceInfo _info(
  String id, {
  String? alias,
  int port = 53318,
  String fp = '',
  List<DeviceAddress> addrs = const [],
}) => DeviceInfo(
  deviceId: id,
  alias: alias ?? 'dev-$id',
  platform: 'linux',
  fingerprint: fp,
  port: port,
  addrs: addrs,
);

/// A full LibreShare instance wired to an in-memory bus. By default all timers
/// are parked far in the future so tests drive announcements explicitly.
class Node {
  Node(
    InMemoryMulticastBus bus,
    String id, {
    String? address,
    int apiPort = 53318,
    PeerRegistrar? registrar,
    NetworkInterfaceProvider? ifaces,
    Clock clock = const SystemClock(),
    List<Duration> schedule = const [],
    Duration periodic = _hour,
    Duration poll = _hour,
    Duration registerTimeout = const Duration(seconds: 2),
    int maxPending = 32,
    Future<void> Function()? onRefresh,
    DeviceInfo Function()? selfInfo,
  }) : info = _info(id, port: apiPort),
       transport = bus.createTransport(address: address) {
    registry = PeerRegistry(selfDeviceId: id, clock: clock);
    discovery = MulticastDiscovery(
      selfInfo: selfInfo ?? () => info,
      transport: transport,
      registry: registry,
      registrar: registrar,
      ifaces: ifaces ?? FakeIfaces(const []),
      clock: clock,
      announceSchedule: schedule,
      periodicInterval: periodic,
      interfacePoll: poll,
      registerTimeout: registerTimeout,
      maxPendingRegistrations: maxPending,
      onRefresh: onRefresh,
    );
  }

  final DeviceInfo info;
  final InMemoryMulticastTransport transport;
  late final PeerRegistry registry;
  late final MulticastDiscovery discovery;

  List<String> get peerIds => [for (final d in registry.current) d.id]..sort();
}

/// A bare bus participant used to inject announcements and capture replies.
class Probe {
  Probe(InMemoryMulticastBus bus, {String address = '10.0.0.50'})
    : transport = bus.createTransport(address: address) {
    transport.packets.listen(received.add);
  }
  final InMemoryMulticastTransport transport;
  final List<MulticastPacket> received = [];

  Future<void> start() => transport.start();

  void announce(DeviceInfo info, {bool announce = true}) =>
      transport.sendMulticast(encodeAnnounce(info, announce: announce));

  List<AnnounceMessage> get decoded => [
    for (final p in received) ?decodeAnnounce(p.data),
  ];
}

Future<void> settle() => pumpEventQueue(times: 50);

Future<void> eventually(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('condition not met in $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late InMemoryMulticastBus bus;
  final nodes = <Node>[];

  Node node(
    String id, {
    String? address,
    PeerRegistrar? registrar,
    int apiPort = 53318,
    FakeClock? clock,
    NetworkInterfaceProvider? ifaces,
    List<Duration> schedule = const [],
    Duration periodic = _hour,
    Duration poll = _hour,
    Duration registerTimeout = const Duration(seconds: 2),
    int maxPending = 32,
    Future<void> Function()? onRefresh,
    DeviceInfo Function()? selfInfo,
  }) {
    final n = Node(
      bus,
      id,
      address: address,
      registrar: registrar,
      apiPort: apiPort,
      clock: clock ?? const SystemClock(),
      ifaces: ifaces,
      schedule: schedule,
      periodic: periodic,
      poll: poll,
      registerTimeout: registerTimeout,
      maxPending: maxPending,
      onRefresh: onRefresh,
      selfInfo: selfInfo,
    );
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

  group('discovery between instances', () {
    test('two instances find each other well within 3 s', () async {
      final sw = Stopwatch()..start();
      final a = node('A');
      final b = node('B');
      await a.discovery.start();
      await b.discovery.start();
      await settle();

      expect(a.peerIds, ['B']);
      expect(b.peerIds, ['A']);
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));

      final seenByB = b.registry.byId('A')!;
      expect(seenByB.source, DiscoverySource.multicast);
      expect(seenByB.address, a.transport.address.address);
      expect(seenByB.info.port, 53318);
      expect(seenByB.info.alias, 'dev-A');
      // A->B was recorded from B's multicast; B->A from A's unicast reply.
      expect(a.registry.byId('B')!.address, b.transport.address.address);
    });

    test(
      'three instances all see each other, nobody sees themselves',
      () async {
        final ns = [node('A'), node('B'), node('C')];
        for (final n in ns) {
          await n.discovery.start();
        }
        await settle();
        expect(ns[0].peerIds, ['B', 'C']);
        expect(ns[1].peerIds, ['A', 'C']);
        expect(ns[2].peerIds, ['A', 'B']);
      },
    );

    test('exposes devices, events and current via the registry', () async {
      final a = node('A');
      final b = node('B');
      final events = <DiscoveryEvent>[];
      a.discovery.events.listen(events.add);
      final snaps = <List<DiscoveredDevice>>[];
      a.discovery.devices.listen(snaps.add);
      await a.discovery.start();
      await b.discovery.start();
      await settle();
      expect(events.single, isA<DeviceFound>());
      expect(events.single.device.id, 'B');
      expect(snaps.last.single.id, 'B');
      expect(a.discovery.current.single.id, 'B');
    });

    test(
      'discovers despite 70% packet loss thanks to periodic announces',
      () async {
        bus = InMemoryMulticastBus(lossRate: 0.7, seed: 42);
        final a = node('A', periodic: const Duration(milliseconds: 15));
        final b = node('B', periodic: const Duration(milliseconds: 15));
        await a.discovery.start();
        await b.discovery.start();
        await eventually(() => a.peerIds.length == 1 && b.peerIds.length == 1);
      },
    );

    test(
      'a blackholed network discovers nothing; healing + refresh recovers',
      () async {
        bus.blackhole = true;
        final a = node('A');
        final b = node('B');
        await a.discovery.start();
        await b.discovery.start();
        await settle();
        expect(a.peerIds, isEmpty);
        expect(b.peerIds, isEmpty);
        expect(bus.sent, isNotEmpty);
        expect(bus.sent.every((s) => s.dropped), isTrue);

        bus.blackhole = false;
        await a.discovery.refresh();
        await settle();
        expect(b.peerIds, ['A']);
        expect(a.peerIds, ['B'], reason: 'via B\'s unicast reply');
      },
    );

    test(
      'multicast blocked but unicast open: replies alone do not discover',
      () async {
        bus.dropMulticast = true;
        final a = node('A');
        final b = node('B');
        await a.discovery.start();
        await b.discovery.start();
        await settle();
        expect(a.peerIds, isEmpty);
        expect(b.peerIds, isEmpty);
        expect(bus.unicasts, isEmpty);
      },
    );
  });

  group('self filtering', () {
    test(
      'own looped-back announcements are not recorded or answered',
      () async {
        final a = node('A');
        final heard = <MulticastPacket>[];
        a.transport.packets.listen(heard.add);
        await a.discovery.start();
        await settle();
        expect(heard, hasLength(1), reason: 'multicast loopback delivered it');
        expect(a.registry.current, isEmpty);
        expect(bus.unicasts, isEmpty);
      },
    );

    test('a packet carrying our own fingerprint is also ignored', () async {
      final a = node(
        'A',
        selfInfo: () => _info('A', fp: _fpA),
        registrar: (_, _) async => fail('must not register with ourselves'),
      );
      final probe = Probe(bus);
      await probe.start();
      await a.discovery.start();
      probe.announce(_info('clone', fp: _fpA));
      await settle();
      expect(a.registry.current, isEmpty);
    });
  });

  group('per-source-IP rate limit (20 packets/s)', () {
    test(
      'a flood from one IP is cut to 20 per second, others unaffected',
      () async {
        final clock = FakeClock();
        final a = node('A', clock: clock);
        final flood = Probe(bus, address: '10.0.0.66');
        final polite = Probe(bus, address: '10.0.0.67');
        await flood.start();
        await polite.start();
        await a.discovery.start();
        await settle();

        for (var i = 0; i < 100; i++) {
          flood.announce(_info('flood-$i'), announce: false);
        }
        polite.announce(_info('polite'), announce: false);
        await settle();

        expect(
          a.registry.current.where((d) => d.id.startsWith('flood-')),
          hasLength(20),
        );
        expect(a.registry.byId('polite'), isNotNull);
        expect(a.discovery.rateLimitedPackets, 80);

        // One second later the bucket has refilled: another 20 get through.
        clock.advance(const Duration(seconds: 1));
        for (var i = 100; i < 130; i++) {
          flood.announce(_info('flood-$i'), announce: false);
        }
        await settle();
        expect(
          a.registry.current.where((d) => d.id.startsWith('flood-')),
          hasLength(40),
        );
        expect(a.discovery.rateLimitedPackets, 90);
      },
    );

    test(
      'limiter memory stays bounded under many spoofed source IPs',
      () async {
        final a = node('A');
        await a.discovery.start();
        for (var i = 0; i < 3000; i++) {
          a.transport.inject(
            utf8.encode('garbage'),
            from: '10.${i >> 8}.${i & 255}.1',
          );
        }
        await settle();
        expect(a.discovery.malformedPackets, 3000);
        expect(a.discovery.trackedSources, lessThanOrEqualTo(1024));
      },
    );
  });

  group('registration and replies', () {
    test('register success: no unicast reply is sent', () async {
      final calls = <(String, String)>[];
      final a = node(
        'A',
        registrar: (peer, address) async {
          calls.add((peer.deviceId, address));
          return true;
        },
      );
      final probe = Probe(bus, address: '10.0.0.50');
      await probe.start();
      await a.discovery.start();
      probe.announce(_info('P', port: 53400));
      await settle();

      expect(calls, [('P', '10.0.0.50')]);
      expect(a.registry.byId('P'), isNotNull);
      expect(bus.unicasts, isEmpty);
      expect(a.discovery.repliesSent, 0);
    });

    test(
      'register returns false: exactly one unicast announce:false',
      () async {
        final a = node('A', apiPort: 53321, registrar: (_, _) async => false);
        final probe = Probe(bus, address: '10.0.0.50');
        await probe.start();
        await a.discovery.start();
        probe.announce(_info('P', port: 53400));
        await settle();

        expect(bus.unicasts, hasLength(1));
        final u = bus.unicasts.single;
        expect(u.from, same(a.transport));
        expect(u.to!.address, '10.0.0.50');
        expect(
          u.toPort,
          probe.transport.port,
          reason: 'reply goes to the peer UDP listener, not its TCP API port',
        );
        final reply = decodeAnnounce(u.data)!;
        expect(reply.announce, isFalse);
        expect(reply.info.deviceId, 'A');
        expect(reply.info.port, 53321);

        // The probe actually received it.
        expect(probe.decoded.where((m) => !m.announce), hasLength(1));
      },
    );

    test('register throws: falls back to one unicast announce:false', () async {
      final a = node(
        'A',
        registrar: (_, _) async => throw const SocketException('boom'),
      );
      final probe = Probe(bus);
      await probe.start();
      await a.discovery.start();
      probe.announce(_info('P'));
      await settle();
      expect(bus.unicasts, hasLength(1));
      expect(decodeAnnounce(bus.unicasts.single.data)!.announce, isFalse);
    });

    test('register synchronously throws: also falls back', () async {
      final a = node('A', registrar: (_, _) => throw StateError('sync'));
      final probe = Probe(bus);
      await probe.start();
      await a.discovery.start();
      probe.announce(_info('P'));
      await settle();
      expect(bus.unicasts, hasLength(1));
    });

    test(
      'register hangs: after the timeout, one unicast announce:false',
      () async {
        final never = Completer<bool>();
        final a = node(
          'A',
          registrar: (_, _) => never.future,
          registerTimeout: const Duration(milliseconds: 40),
        );
        final probe = Probe(bus);
        await probe.start();
        await a.discovery.start();
        probe.announce(_info('P'));
        await settle();
        expect(bus.unicasts, isEmpty, reason: 'still waiting for the POST');
        await eventually(() => bus.unicasts.length == 1);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(bus.unicasts, hasLength(1));
      },
    );

    test('a hanging registrar completing late changes nothing', () async {
      final late = Completer<bool>();
      final a = node(
        'A',
        registrar: (_, _) => late.future,
        registerTimeout: const Duration(milliseconds: 20),
      );
      final probe = Probe(bus);
      await probe.start();
      await a.discovery.start();
      probe.announce(_info('P'));
      await eventually(() => bus.unicasts.length == 1);
      late.completeError(StateError('too late'));
      await settle();
      expect(bus.unicasts, hasLength(1));
    });

    test(
      'no registrar configured: replies with unicast announce:false',
      () async {
        final a = node('A');
        final probe = Probe(bus);
        await probe.start();
        await a.discovery.start();
        probe.announce(_info('P'));
        await settle();
        expect(bus.unicasts, hasLength(1));
      },
    );

    test('announce:false is recorded but never answered', () async {
      var registrarCalls = 0;
      final a = node(
        'A',
        registrar: (_, _) async {
          registrarCalls++;
          return false;
        },
      );
      final probe = Probe(bus);
      await probe.start();
      await a.discovery.start();
      probe.announce(_info('P'), announce: false);
      await settle();

      expect(a.peerIds, ['P'], reason: 'recorded');
      expect(registrarCalls, 0);
      expect(bus.unicasts, isEmpty);
      expect(a.discovery.repliesSent, 0);
      // Only our own start-up multicast went out.
      expect(bus.multicasts.where((s) => s.from == a.transport), hasLength(1));
    });

    test('two instances never ping-pong: bounded traffic', () async {
      final a = node('A');
      final b = node('B');
      await a.discovery.start();
      await b.discovery.start();
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await settle();
      expect(bus.multicasts, hasLength(2), reason: 'one announce each');
      expect(bus.unicasts, hasLength(1), reason: 'A answered B once');
    });

    test(
      'burst re-announcements from a known peer are answered only once',
      () async {
        var calls = 0;
        final a = node(
          'A',
          registrar: (_, _) async {
            calls++;
            return false;
          },
        );
        final probe = Probe(bus);
        await probe.start();
        await a.discovery.start();
        for (var i = 0; i < 5; i++) {
          probe.announce(_info('P'));
          await settle();
        }
        expect(calls, 1);
        expect(bus.unicasts, hasLength(1));
      },
    );

    test('a changed fingerprint on a known peer is answered again', () async {
      var calls = 0;
      final a = node(
        'A',
        registrar: (_, _) async {
          calls++;
          return true;
        },
      );
      final probe = Probe(bus);
      await probe.start();
      await a.discovery.start();
      probe.announce(_info('P', fp: _fpA));
      await settle();
      probe.announce(_info('P', fp: _fpA));
      await settle();
      expect(calls, 1);

      probe.announce(_info('P', fp: _fpB));
      await settle();
      expect(calls, 2);
      expect(a.registry.fingerprintChanged('P'), isTrue);
      probe.announce(_info('P', fp: _fpB));
      await settle();
      expect(calls, 2, reason: 'already registered under the new fingerprint');
    });

    test('too many registrations in flight overflow to UDP replies', () async {
      final pending = Completer<bool>();
      final a = node(
        'A',
        registrar: (_, _) => pending.future,
        maxPending: 1,
        registerTimeout: _hour,
      );
      final probe = Probe(bus);
      await probe.start();
      await a.discovery.start();
      probe.announce(_info('P1'));
      probe.announce(_info('P2'));
      await settle();
      expect(bus.unicasts, hasLength(1), reason: 'P2 was not queued behind P1');
      pending.complete(true);
    });
  });

  group('hostile input', () {
    test('malformed, oversize and foreign datagrams are ignored', () async {
      final a = node('A');
      await a.discovery.start();
      final good = encodeAnnounce(_info('X'), announce: true);
      final doc = jsonDecode(utf8.decode(good)) as Map<String, Object?>;
      Uint8List enc(Map<String, Object?> m) =>
          Uint8List.fromList(utf8.encode(jsonEncode(m)));

      final bad = <List<int>>[
        const [],
        utf8.encode('hello'),
        List<int>.filled(1201, 0x20),
        enc({...doc, 'pad': 'z' * 1200}),
        enc({...doc, 'v': '2.0'}),
        enc({...doc, 'proto': 'localsend'}),
        enc({...doc, 'port': 0}),
        enc({...doc, 'alias': 'ctl\u0007'}),
        [0xff, 0xfe, 0x00],
      ];
      for (final b in bad) {
        a.transport.inject(b, from: '10.0.0.77');
      }
      await settle();

      expect(a.registry.current, isEmpty);
      expect(a.discovery.malformedPackets, bad.length);
      expect(bus.unicasts, isEmpty);
      expect(a.discovery.isRunning, isTrue);

      // And a good one still works afterwards.
      a.transport.inject(good, from: '10.0.0.77');
      await settle();
      expect(a.peerIds, ['X']);
    });
  });

  group('announce schedule', () {
    test('start, +offsets, then periodic', () async {
      final a = node(
        'A',
        schedule: const [
          Duration(milliseconds: 40),
          Duration(milliseconds: 120),
        ],
        periodic: const Duration(milliseconds: 450),
      );
      await a.discovery.start();
      expect(a.discovery.announcesSent, 1, reason: 'immediately at start');
      await eventually(() => a.discovery.announcesSent == 2);
      await eventually(() => a.discovery.announcesSent == 3);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(a.discovery.announcesSent, 3, reason: 'nothing before 450 ms');
      await eventually(() => a.discovery.announcesSent >= 4);
      expect(
        bus.multicasts.every((s) => decodeAnnounce(s.data)!.announce),
        isTrue,
      );
    });

    test('default schedule is start, +1 s, +3 s, every 30 s, poll 5 s', () {
      final d = MulticastDiscovery(
        selfInfo: () => _info('A'),
        transport: bus.createTransport(),
        registry: PeerRegistry(selfDeviceId: 'A'),
      );
      expect(d.announceSchedule, const [
        Duration(seconds: 1),
        Duration(seconds: 3),
      ]);
      expect(d.periodicInterval, const Duration(seconds: 30));
      expect(d.interfacePoll, const Duration(seconds: 5));
      expect(d.registerTimeout, const Duration(seconds: 2));
    });

    test('selfInfo is evaluated at every announce', () async {
      var alias = 'Before';
      var port = 53318;
      final a = node(
        'A',
        selfInfo: () => _info('A', alias: alias, port: port),
      );
      await a.discovery.start();
      alias = 'After';
      port = 53330;
      await a.discovery.refresh();
      final last = decodeAnnounce(bus.multicasts.last.data)!;
      expect(last.info.alias, 'After');
      expect(last.info.port, 53330);
      expect(decodeAnnounce(bus.multicasts.first.data)!.info.alias, 'Before');
    });

    test('does not announce while the API port is not a real port', () async {
      final a = node('A', apiPort: 0);
      await a.discovery.start();
      await a.discovery.refresh();
      expect(a.discovery.announcesSent, 0);
      expect(bus.sent, isEmpty);
    });

    test(
      'an unencodable self is skipped without killing the schedule',
      () async {
        var bad = true;
        final a = node(
          'A',
          selfInfo: () =>
              bad ? _info('A', fp: 'not-a-fingerprint') : _info('A'),
        );
        await a.discovery.start();
        expect(a.discovery.announcesSent, 0);
        bad = false;
        await a.discovery.refresh();
        expect(a.discovery.announcesSent, 1);
      },
    );

    test('refresh re-announces immediately and runs the hook', () async {
      var hook = 0;
      final a = node('A', onRefresh: () async => hook++);
      await a.discovery.start();
      expect(a.discovery.announcesSent, 1);
      await a.discovery.refresh();
      expect(a.discovery.announcesSent, 2);
      expect(hook, 1);
    });

    test('a failing refresh hook does not propagate', () async {
      final a = node('A', onRefresh: () async => throw StateError('scan'));
      await a.discovery.start();
      await a.discovery.refresh();
      expect(a.discovery.announcesSent, 2);
    });

    test('refresh before start does nothing', () async {
      final a = node('A');
      await a.discovery.refresh();
      expect(bus.sent, isEmpty);
    });
  });

  group('network interface changes', () {
    test(
      'a changed interface set re-joins and re-announces with new addrs',
      () async {
        final ifaces = FakeIfaces([_iface('wlan0', '192.168.1.23')]);
        final a = node(
          'A',
          ifaces: ifaces,
          poll: const Duration(milliseconds: 20),
        );
        await a.discovery.start();
        expect(a.discovery.announcesSent, 1);
        expect(
          decodeAnnounce(bus.multicasts.single.data)!.info.addrs.single.ip,
          '192.168.1.23',
        );

        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(a.discovery.announcesSent, 1, reason: 'unchanged => quiet');
        expect(a.transport.rejoinCount, 0);

        ifaces.items = [
          _iface('wlan0', '192.168.1.23'),
          _iface('eth0', '10.0.0.5', 'ethernet'),
        ];
        await eventually(() => a.discovery.announcesSent == 2);
        expect(a.transport.rejoinCount, 1);
        final addrs = decodeAnnounce(bus.multicasts.last.data)!.info.addrs;
        expect(
          addrs.map((x) => x.ip),
          unorderedEquals(['192.168.1.23', '10.0.0.5']),
        );

        // Same set in a different order is not a change.
        ifaces.items = ifaces.items.reversed.toList();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(a.discovery.announcesSent, 2);

        // A new address on the same interface (DHCP renewal) is a change.
        ifaces.items = [
          _iface('wlan0', '192.168.1.99'),
          _iface('eth0', '10.0.0.5', 'ethernet'),
        ];
        await eventually(() => a.discovery.announcesSent == 3);
        expect(a.transport.rejoinCount, 2);
      },
    );

    test('loopback addresses are never advertised', () async {
      final a = node(
        'A',
        ifaces: FakeIfaces([
          _iface('lo', '127.0.0.1', 'unknown'),
          _iface('wlan0', '10.1.1.1'),
        ]),
      );
      await a.discovery.start();
      final addrs = decodeAnnounce(bus.multicasts.single.data)!.info.addrs;
      expect(addrs.map((x) => x.ip), ['10.1.1.1']);
      expect(addrs.single.iface, 'wifi');
    });

    test(
      'addresses configured in selfInfo win over discovered interfaces',
      () async {
        final a = node(
          'A',
          ifaces: FakeIfaces([_iface('wlan0', '10.1.1.1')]),
          selfInfo: () => _info(
            'A',
            addrs: const [DeviceAddress('172.16.0.4', iface: 'ethernet')],
          ),
        );
        await a.discovery.start();
        final addrs = decodeAnnounce(bus.multicasts.single.data)!.info.addrs;
        expect(addrs.single.ip, '172.16.0.4');
      },
    );

    test('a throwing interface provider does not break announcing', () async {
      final a = node(
        'A',
        ifaces: _ThrowingIfaces(),
        poll: const Duration(milliseconds: 10),
      );
      await a.discovery.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(a.discovery.announcesSent, 1);
      expect(a.discovery.isRunning, isTrue);
    });
  });

  group('lifecycle', () {
    test(
      'stop sends nothing, cancels timers and closes the transport',
      () async {
        final a = node(
          'A',
          schedule: const [Duration(milliseconds: 20)],
          periodic: const Duration(milliseconds: 30),
          poll: const Duration(milliseconds: 10),
        );
        await a.discovery.start();
        await eventually(() => a.discovery.announcesSent >= 3);

        final before = bus.sent.length;
        await a.discovery.stop();
        expect(a.discovery.isRunning, isFalse);
        expect(a.transport.isStarted, isFalse);
        expect(bus.sent.length, before, reason: 'no goodbye packet');

        final count = a.discovery.announcesSent;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(a.discovery.announcesSent, count);
        expect(bus.sent.length, before);
      },
    );

    test('stop is idempotent and start can follow stop', () async {
      final a = node('A');
      await a.discovery.stop();
      await a.discovery.start();
      await a.discovery.start(); // second start is a no-op
      expect(a.discovery.announcesSent, 1);
      await a.discovery.stop();
      await a.discovery.stop();
      await a.discovery.start();
      expect(a.discovery.announcesSent, 2);
      expect(a.discovery.isRunning, isTrue);
    });

    test('packets arriving after stop are ignored', () async {
      final a = node('A');
      final probe = Probe(bus);
      await probe.start();
      await a.discovery.start();
      await a.discovery.stop();
      probe.announce(_info('P'));
      await settle();
      expect(a.registry.current, isEmpty);
    });

    test('stop does not dispose the shared registry', () async {
      final a = node('A');
      final b = node('B');
      await a.discovery.start();
      await b.discovery.start();
      await settle();
      await a.discovery.stop();
      expect(a.peerIds, ['B']);
      a.registry.seen(_info('Z'), '10.9.9.9', DiscoverySource.manual);
      expect(a.peerIds, ['B', 'Z']);
    });

    test(
      'start owns the registry sweep timer only if nobody started it',
      () async {
        final a = node('A');
        expect(a.registry.isRunning, isFalse);
        await a.discovery.start();
        expect(a.registry.isRunning, isTrue);
        await a.discovery.stop();
        expect(a.registry.isRunning, isFalse);

        final b = node('B');
        b.registry.start();
        await b.discovery.start();
        await b.discovery.stop();
        expect(b.registry.isRunning, isTrue, reason: 'someone else owns it');
      },
    );

    test(
      'a transport that cannot start makes start() throw and leaves it stopped',
      () async {
        final registry = PeerRegistry(selfDeviceId: 'A');
        addTearDown(registry.dispose);
        final d = MulticastDiscovery(
          selfInfo: () => _info('A'),
          transport: _FailingTransport(),
          registry: registry,
        );
        await expectLater(d.start(), throwsA(isA<SocketException>()));
        expect(d.isRunning, isFalse);
        await d.stop(); // harmless
      },
    );
  });
}

class _ThrowingIfaces implements NetworkInterfaceProvider {
  @override
  Future<List<LocalInterface>> list() async => throw const OSError('no ifaces');
}

class _FailingTransport implements MulticastTransport {
  @override
  Stream<MulticastPacket> get packets => const Stream.empty();
  int startCalls = 0;
  @override
  Future<void> start() async {
    startCalls++;
    throw const SocketException('address in use');
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> rejoin() async {}
  @override
  void sendMulticast(List<int> data) {}
  @override
  void sendUnicast(List<int> data, InternetAddress address, int port) {}
}
