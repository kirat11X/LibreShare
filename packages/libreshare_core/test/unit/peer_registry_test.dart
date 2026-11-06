import 'dart:async';

import 'package:libreshare_core/src/clock.dart';
import 'package:libreshare_core/src/discovery/device_discovery.dart';
import 'package:libreshare_core/src/discovery/peer_registry.dart';
import 'package:libreshare_core/src/model/device.dart';
import 'package:test/test.dart';

class FakeClock implements Clock {
  FakeClock([DateTime? start]) : _now = start ?? DateTime.utc(2026, 11, 3, 12);
  DateTime _now;
  @override
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

const _fpA = 'AA00000000000000000000000000000000000000000000000000000000000001';
const _fpB = 'BB00000000000000000000000000000000000000000000000000000000000002';

DeviceInfo _dev(
  String id, {
  String alias = 'Peer',
  String fp = '',
  int port = 53318,
  List<DeviceAddress> addrs = const [],
}) => DeviceInfo(
  deviceId: id,
  alias: alias,
  platform: 'linux',
  fingerprint: fp,
  port: port,
  addrs: addrs,
);

void main() {
  late FakeClock clock;
  late PeerRegistry reg;
  late List<DiscoveryEvent> events;
  late StreamSubscription<DiscoveryEvent> sub;

  setUp(() {
    clock = FakeClock();
    reg = PeerRegistry(selfDeviceId: 'self', clock: clock);
    events = [];
    sub = reg.events.listen(events.add);
  });

  tearDown(() async {
    await sub.cancel();
    reg.dispose();
  });

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('defaults: 90 s expiry, 1024 peers', () {
    expect(reg.expiry, const Duration(seconds: 90));
    expect(reg.maxPeers, 1024);
  });

  test('first sighting emits DeviceFound and appears in current', () async {
    reg.seen(_dev('a', alias: 'Alice'), '10.0.0.2', DiscoverySource.multicast);
    await pump();
    expect(events.single, isA<DeviceFound>());
    final d = reg.current.single;
    expect(d.id, 'a');
    expect(d.info.alias, 'Alice');
    expect(d.address, '10.0.0.2');
    expect(d.source, DiscoverySource.multicast);
    expect(d.lastSeen, clock.now());
    expect(reg.byId('a'), same(d));
    expect(reg.byId('zzz'), isNull);
  });

  test('second sighting emits DeviceUpdated and refreshes lastSeen', () async {
    reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
    final t0 = clock.now();
    clock.advance(const Duration(seconds: 30));
    reg.seen(_dev('a', alias: 'Alice2'), '10.0.0.2', DiscoverySource.manual);
    await pump();
    expect(events.map((e) => e.runtimeType), [DeviceFound, DeviceUpdated]);
    expect(reg.current, hasLength(1));
    final d = reg.current.single;
    expect(d.info.alias, 'Alice2');
    expect(d.lastSeen, t0.add(const Duration(seconds: 30)));
    expect(d.source, DiscoverySource.manual, reason: 'latest source wins');
  });

  test('own deviceId (and empty ids) are ignored', () async {
    reg.seen(_dev('self'), '10.0.0.1', DiscoverySource.multicast);
    reg.seen(_dev(''), '10.0.0.1', DiscoverySource.multicast);
    await pump();
    expect(reg.current, isEmpty);
    expect(events, isEmpty);
  });

  group('expiry', () {
    test('peer survives just under 90 s and is lost at 90 s', () async {
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      clock.advance(const Duration(seconds: 89, milliseconds: 999));
      expect(reg.sweep(), 0);
      expect(reg.current, hasLength(1));

      clock.advance(const Duration(milliseconds: 1));
      expect(reg.sweep(), 1);
      await pump();
      expect(reg.current, isEmpty);
      expect(events.map((e) => e.runtimeType), [DeviceFound, DeviceLost]);
      expect(events.last.device.id, 'a');
    });

    test('re-sighting restarts the 90 s window', () async {
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      clock.advance(const Duration(seconds: 80));
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      clock.advance(const Duration(seconds: 80));
      expect(reg.sweep(), 0);
      clock.advance(const Duration(seconds: 10));
      expect(reg.sweep(), 1);
    });

    test('only stale peers are removed', () async {
      reg.seen(_dev('old'), '10.0.0.2', DiscoverySource.multicast);
      clock.advance(const Duration(seconds: 60));
      reg.seen(_dev('new'), '10.0.0.3', DiscoverySource.multicast);
      clock.advance(const Duration(seconds: 40));
      expect(reg.sweep(), 1);
      expect(reg.current.map((d) => d.id), ['new']);
    });

    test('custom expiry is honoured', () {
      final r = PeerRegistry(
        selfDeviceId: 'self',
        clock: clock,
        expiry: const Duration(seconds: 5),
      );
      addTearDown(r.dispose);
      r.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      clock.advance(const Duration(seconds: 5));
      expect(r.sweep(), 1);
    });

    test('periodic timer sweeps by itself once start()ed', () async {
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      expect(reg.isRunning, isFalse);
      reg.start(sweepInterval: const Duration(milliseconds: 10));
      reg.start(sweepInterval: const Duration(milliseconds: 10)); // idempotent
      expect(reg.isRunning, isTrue);
      clock.advance(const Duration(seconds: 91));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(reg.current, isEmpty);
      expect(events.last, isA<DeviceLost>());
      reg.stop();
      expect(reg.isRunning, isFalse);
    });
  });

  group('snapshot stream', () {
    test(
      'emits after found, updated and lost; late listeners get no replay',
      () async {
        reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
        final snaps = <List<DiscoveredDevice>>[];
        final s = reg.devices.listen(snaps.add);
        await pump();
        expect(snaps, isEmpty, reason: 'no replay of past state');

        reg.seen(_dev('b'), '10.0.0.3', DiscoverySource.multicast);
        reg.seen(_dev('b', alias: 'B2'), '10.0.0.3', DiscoverySource.multicast);
        clock.advance(const Duration(seconds: 100));
        reg.sweep();
        await pump();
        expect(snaps.map((l) => l.length), [2, 2, 0]);
        expect(snaps[1].last.info.alias, 'B2');
        await s.cancel();
      },
    );

    test('snapshots and current are unmodifiable', () {
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      expect(() => reg.current.clear(), throwsUnsupportedError);
    });

    test('sweep with nothing to remove emits nothing', () async {
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      final snaps = <List<DiscoveredDevice>>[];
      final s = reg.devices.listen(snaps.add);
      reg.sweep();
      await pump();
      expect(snaps, isEmpty);
      await s.cancel();
    });
  });

  group('addresses', () {
    test('new address replaces address but keeps the old one in addrs', () {
      reg.seen(
        _dev('a', addrs: const [DeviceAddress('10.0.0.2', iface: 'wifi')]),
        '10.0.0.2',
        DiscoverySource.multicast,
      );
      reg.seen(
        _dev('a', addrs: const [DeviceAddress('192.168.1.9', iface: 'wifi')]),
        '192.168.1.9',
        DiscoverySource.multicast,
      );
      final d = reg.current.single;
      expect(d.address, '192.168.1.9');
      expect(d.info.addrs.map((a) => a.ip), ['192.168.1.9', '10.0.0.2']);
      expect(d.info.addrs.last.iface, 'wifi', reason: 'iface class kept');
    });

    test('previous address is kept even if it was not self-reported', () {
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      reg.seen(_dev('a'), '10.0.0.3', DiscoverySource.subnetScan);
      reg.seen(_dev('a'), '10.0.0.4', DiscoverySource.subnetScan);
      expect(reg.current.single.info.addrs.map((a) => a.ip), [
        '10.0.0.3',
        '10.0.0.2',
      ]);
      expect(reg.current.single.address, '10.0.0.4');
    });

    test('address list stays bounded and de-duplicated', () {
      for (var i = 0; i < 100; i++) {
        reg.seen(_dev('a'), '10.9.0.${i % 50}', DiscoverySource.multicast);
      }
      final ips = reg.current.single.info.addrs.map((a) => a.ip).toList();
      expect(ips.length, lessThanOrEqualTo(PeerRegistry.maxAddrsPerPeer));
      expect(ips.toSet().length, ips.length);
    });

    test('same address leaves the self-reported addrs untouched', () {
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      reg.seen(
        _dev('a', addrs: const [DeviceAddress('10.0.0.2')]),
        '10.0.0.2',
        DiscoverySource.multicast,
      );
      expect(reg.current.single.info.addrs.map((a) => a.ip), ['10.0.0.2']);
    });
  });

  group('maxPeers', () {
    test(
      'never exceeds the cap; least recently seen is evicted as Lost',
      () async {
        final r = PeerRegistry(selfDeviceId: 'self', clock: clock, maxPeers: 3);
        addTearDown(r.dispose);
        final evs = <DiscoveryEvent>[];
        final s = r.events.listen(evs.add);
        addTearDown(s.cancel);

        for (final id in ['a', 'b', 'c']) {
          r.seen(_dev(id), '10.0.0.1', DiscoverySource.multicast);
          clock.advance(const Duration(seconds: 1));
        }
        // Refresh 'a' so 'b' is now the least recently seen.
        r.seen(_dev('a'), '10.0.0.1', DiscoverySource.multicast);
        clock.advance(const Duration(seconds: 1));
        r.seen(_dev('d'), '10.0.0.1', DiscoverySource.multicast);
        await pump();

        expect(r.current.map((d) => d.id), unorderedEquals(['a', 'c', 'd']));
        final lost = evs.whereType<DeviceLost>().single;
        expect(lost.device.id, 'b');
        expect(evs.last, isA<DeviceFound>());
        expect(evs.last.device.id, 'd');
      },
    );

    test('flooding with 10,000 distinct ids stays at the cap', () {
      final r = PeerRegistry(selfDeviceId: 'self', clock: clock, maxPeers: 50);
      addTearDown(r.dispose);
      for (var i = 0; i < 10000; i++) {
        clock.advance(const Duration(milliseconds: 1));
        r.seen(_dev('id-$i'), '10.0.0.1', DiscoverySource.multicast);
        expect(r.current.length, lessThanOrEqualTo(50));
      }
      expect(r.current.length, 50);
      expect(r.byId('id-9999'), isNotNull);
      expect(r.byId('id-0'), isNull);
    });

    test('rejects a non-positive cap', () {
      expect(
        () => PeerRegistry(selfDeviceId: 's', maxPeers: 0),
        throwsArgumentError,
      );
    });
  });

  group('fingerprintChanged', () {
    test('false for unknown peers and for pre-TLS (empty) fingerprints', () {
      expect(reg.fingerprintChanged('nobody'), isFalse);
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      expect(reg.fingerprintChanged('a'), isFalse);
      expect(reg.knownFingerprint('a'), isNull);
    });

    test('first fingerprint is adopted silently ("" -> hex is an upgrade)', () {
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      reg.seen(_dev('a', fp: _fpA), '10.0.0.2', DiscoverySource.multicast);
      expect(reg.fingerprintChanged('a'), isFalse);
      expect(reg.knownFingerprint('a'), _fpA);
    });

    test(
      'a different fingerprint is surfaced as an update but flagged',
      () async {
        reg.seen(_dev('a', fp: _fpA), '10.0.0.2', DiscoverySource.multicast);
        reg.seen(_dev('a', fp: _fpB), '10.0.0.2', DiscoverySource.multicast);
        await pump();

        expect(events.map((e) => e.runtimeType), [DeviceFound, DeviceUpdated]);
        expect(reg.fingerprintChanged('a'), isTrue);
        expect(
          reg.knownFingerprint('a'),
          _fpA,
          reason: 'baseline not replaced',
        );
        expect(reg.current.single.info.fingerprint, _fpB, reason: 'visible');
      },
    );

    test('flag persists on later sightings of the new fingerprint', () {
      reg.seen(_dev('a', fp: _fpA), '10.0.0.2', DiscoverySource.multicast);
      reg.seen(_dev('a', fp: _fpB), '10.0.0.2', DiscoverySource.multicast);
      reg.seen(_dev('a', fp: _fpB), '10.0.0.2', DiscoverySource.multicast);
      expect(reg.fingerprintChanged('a'), isTrue);
    });

    test('returning to the original fingerprint clears the flag', () {
      reg.seen(_dev('a', fp: _fpA), '10.0.0.2', DiscoverySource.multicast);
      reg.seen(_dev('a', fp: _fpB), '10.0.0.2', DiscoverySource.multicast);
      reg.seen(_dev('a', fp: _fpA), '10.0.0.2', DiscoverySource.multicast);
      expect(reg.fingerprintChanged('a'), isFalse);
    });

    test('acceptFingerprint adopts the new fingerprint as baseline', () {
      reg.seen(_dev('a', fp: _fpA), '10.0.0.2', DiscoverySource.multicast);
      reg.seen(_dev('a', fp: _fpB), '10.0.0.2', DiscoverySource.multicast);
      expect(reg.acceptFingerprint('a'), isTrue);
      expect(reg.fingerprintChanged('a'), isFalse);
      expect(reg.knownFingerprint('a'), _fpB);
      reg.seen(_dev('a', fp: _fpB), '10.0.0.2', DiscoverySource.multicast);
      expect(reg.fingerprintChanged('a'), isFalse);
      expect(reg.acceptFingerprint('ghost'), isFalse);
    });

    test('comparison ignores case', () {
      reg.seen(_dev('a', fp: _fpA), '10.0.0.2', DiscoverySource.multicast);
      reg.seen(
        _dev('a', fp: _fpA.toLowerCase()),
        '10.0.0.2',
        DiscoverySource.multicast,
      );
      expect(reg.fingerprintChanged('a'), isFalse);
      expect(reg.current.single.info.fingerprint, _fpA);
    });

    test('a source without a fingerprint neither blanks nor flags', () {
      reg.seen(_dev('a', fp: _fpA), '10.0.0.2', DiscoverySource.multicast);
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.mdns);
      expect(reg.fingerprintChanged('a'), isFalse);
      expect(reg.current.single.info.fingerprint, _fpA);

      reg.seen(_dev('a', fp: _fpB), '10.0.0.2', DiscoverySource.multicast);
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.mdns);
      expect(reg.fingerprintChanged('a'), isTrue, reason: 'alarm not cleared');
      expect(reg.current.single.info.fingerprint, _fpB);
    });

    test(
      'baseline survives expiry: a returning peer with a new fp is flagged',
      () {
        reg.seen(_dev('a', fp: _fpA), '10.0.0.2', DiscoverySource.multicast);
        clock.advance(const Duration(seconds: 100));
        reg.sweep();
        expect(reg.current, isEmpty);
        reg.seen(_dev('a', fp: _fpB), '10.0.0.2', DiscoverySource.multicast);
        expect(reg.fingerprintChanged('a'), isTrue);
      },
    );
  });

  test('dispose closes streams and ignores further input', () async {
    final done = reg.events.toList();
    reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
    reg.dispose();
    reg.dispose(); // idempotent
    reg.seen(_dev('b'), '10.0.0.3', DiscoverySource.multicast);
    expect(reg.current, isEmpty);
    expect((await done).map((e) => e.device.id), ['a']);
  });
}
