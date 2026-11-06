// SubnetScanner + ScanPolicy (spec 4.2 rule 4): /24 sweep over private ranges
// with a bounded worker pool, incremental reporting, caps and cancellation.
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class FakeIfaces implements NetworkInterfaceProvider {
  FakeIfaces(this.items);
  List<LocalInterface> items;
  int listCalls = 0;
  Object? failWith;

  @override
  Future<List<LocalInterface>> list() async {
    listCalls++;
    if (failWith != null) throw failWith!;
    return items;
  }
}

LocalInterface iface(
  String ip, {
  String name = 'wlan0',
  String kind = 'wifi',
}) => LocalInterface(name: name, address: InternetAddress(ip), kind: kind);

class Seen {
  Seen(this.info, this.address, this.source);
  final DeviceInfo info;
  final String address;
  final DiscoverySource source;
}

class RecordingSink implements PeerSink {
  final List<Seen> seen_ = [];
  final List<Completer<void>> _waiters = [];
  void Function(DeviceInfo)? onSeen;

  @override
  void seen(DeviceInfo info, String address, DiscoverySource source) {
    seen_.add(Seen(info, address, source));
    onSeen?.call(info);
    for (final w in _waiters.toList()) {
      if (!w.isCompleted) w.complete();
    }
  }

  Future<void> nextSeen() {
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }
}

DeviceInfo device(String id, {int port = kDefaultPort}) =>
    DeviceInfo(deviceId: id, alias: 'Dev $id', platform: 'linux', port: port);

/// Probe that answers with [answers] by ip, instantly, and records calls.
class ScriptedProbe {
  ScriptedProbe([Map<String, DeviceInfo>? answers]) : answers = answers ?? {};
  final Map<String, DeviceInfo> answers;
  final List<String> ips = [];
  final List<int> ports = [];
  final List<Duration> timeouts = [];
  int inFlight = 0;
  int peak = 0;
  Duration delay = Duration.zero;

  Future<DeviceInfo?> call(String ip, int port, Duration timeout) async {
    ips.add(ip);
    ports.add(port);
    timeouts.add(timeout);
    inFlight++;
    if (inFlight > peak) peak = inFlight;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      return answers[ip];
    } finally {
      inFlight--;
    }
  }
}

class FakeClock implements Clock {
  DateTime t = DateTime.utc(2026, 1, 1);
  Duration step = const Duration(seconds: 3);
  @override
  DateTime now() {
    final v = t;
    t = t.add(step);
    return v;
  }
}

SubnetScanner scannerFor(
  List<LocalInterface> ifaces,
  RecordingSink sink,
  InfoProbe probe, {
  int concurrency = 64,
  Duration timeout = const Duration(milliseconds: 800),
  int port = kDefaultPort,
  int maxProbes = SubnetScanner.defaultMaxProbes,
  bool allowLoopback = false,
  Clock clock = const SystemClock(),
}) => SubnetScanner(
  ifaces: FakeIfaces(ifaces),
  sink: sink,
  probe: probe,
  concurrency: concurrency,
  timeout: timeout,
  port: port,
  maxProbes: maxProbes,
  allowLoopback: allowLoopback,
  clock: clock,
);

void main() {
  group('SubnetScanner - what gets probed', () {
    test('defaults match the spec: 64 concurrent, 800 ms, port 53318', () {
      expect(SubnetScanner.defaultConcurrency, 64);
      expect(SubnetScanner.defaultTimeout, const Duration(milliseconds: 800));
      expect(SubnetScanner.defaultMaxProbes, 4096);
      final probe = ScriptedProbe();
      final s = SubnetScanner(
        ifaces: FakeIfaces([]),
        sink: RecordingSink(),
        probe: probe.call,
      );
      expect(s.concurrency, 64);
      expect(s.timeout, const Duration(milliseconds: 800));
      expect(s.port, kDefaultPort);
    });

    test('finds a peer on .77 and reports it to the sink', () async {
      final sink = RecordingSink();
      final probe = ScriptedProbe({'192.168.1.77': device('peer-77')});
      final r = await scannerFor(
        [iface('192.168.1.23')],
        sink,
        probe.call,
      ).scan();
      expect(r.found.map((d) => d.deviceId), ['peer-77']);
      expect(r.probed, 253, reason: '.1-.254 without our own .23');
      expect(sink.seen_, hasLength(1));
      expect(sink.seen_.single.info.deviceId, 'peer-77');
      expect(sink.seen_.single.address, '192.168.1.77');
      expect(sink.seen_.single.source, DiscoverySource.subnetScan);
      expect(probe.ips.toSet(), hasLength(253), reason: 'each host once');
      expect(probe.ports.toSet(), {kDefaultPort});
      expect(probe.timeouts.toSet(), {const Duration(milliseconds: 800)});
    });

    test(
      'probes exactly hosts .1-.254 of the /24, never .0/.255/own',
      () async {
        final probe = ScriptedProbe();
        await scannerFor(
          [iface('10.9.8.50')],
          RecordingSink(),
          probe.call,
        ).scan();
        expect(probe.ips, isNot(contains('10.9.8.0')));
        expect(probe.ips, isNot(contains('10.9.8.255')));
        expect(probe.ips, isNot(contains('10.9.8.50')), reason: 'own address');
        expect(probe.ips, containsAll(['10.9.8.1', '10.9.8.254']));
        expect(probe.ips.every((ip) => ip.startsWith('10.9.8.')), isTrue);
        expect(probe.ips, hasLength(253));
      },
    );

    test('uses the configured port', () async {
      final probe = ScriptedProbe();
      await scannerFor(
        [iface('10.0.0.2')],
        RecordingSink(),
        probe.call,
        port: 53325,
      ).scan();
      expect(probe.ports.toSet(), {53325});
    });

    test('private ranges are scanned; others are refused', () async {
      Future<List<String>> scanned(
        String ip, {
        bool allowLoopback = false,
      }) async {
        final probe = ScriptedProbe();
        await scannerFor(
          [iface(ip)],
          RecordingSink(),
          probe.call,
          allowLoopback: allowLoopback,
        ).scan();
        return probe.ips;
      }

      for (final ip in [
        '10.0.0.9',
        '10.255.255.9',
        '172.16.0.9',
        '172.31.255.9',
        '192.168.0.9',
        '192.168.255.9',
        '169.254.7.9', // link-local
        '100.64.0.9', // CGNAT
        '100.127.255.9',
      ]) {
        expect(await scanned(ip), hasLength(253), reason: '$ip is private');
      }
      for (final ip in [
        '8.8.8.8',
        '1.1.1.1',
        '11.0.0.9',
        '9.255.255.9',
        '172.15.255.9', // just below 172.16/12
        '172.32.0.9', // just above
        '192.167.1.9',
        '192.169.1.9',
        '169.253.1.9',
        '169.255.1.9',
        '100.63.255.9', // just below CGNAT
        '100.128.0.9', // just above
        '127.0.0.5', // loopback unless explicitly allowed
        '0.0.0.5',
        '224.0.0.5',
        '240.0.0.5',
        '255.255.255.5',
        '203.0.113.9', // TEST-NET-3 / public
      ]) {
        expect(await scanned(ip), isEmpty, reason: '$ip must not be scanned');
      }
      expect(await scanned('127.0.0.5', allowLoopback: true), hasLength(253));
    });

    test('a public interface never makes a private one get skipped', () async {
      final probe = ScriptedProbe();
      final r = await scannerFor(
        [iface('203.0.113.9', name: 'eth9'), iface('192.168.7.2')],
        RecordingSink(),
        probe.call,
      ).scan();
      expect(r.probed, 253);
      expect(probe.ips.every((ip) => ip.startsWith('192.168.7.')), isTrue);
    });

    test('IPv6 interfaces are ignored', () async {
      final probe = ScriptedProbe();
      final r = await scannerFor(
        [iface('fe80::1'), iface('fd00::5')],
        RecordingSink(),
        probe.call,
      ).scan();
      expect(r.probed, 0);
      expect(probe.ips, isEmpty);
    });

    test('two addresses in one /24 are swept once, both excluded', () async {
      final probe = ScriptedProbe();
      final r = await scannerFor(
        [iface('192.168.1.5'), iface('192.168.1.6', name: 'eth0')],
        RecordingSink(),
        probe.call,
      ).scan();
      expect(r.probed, 252);
      expect(probe.ips, isNot(contains('192.168.1.5')));
      expect(probe.ips, isNot(contains('192.168.1.6')));
      expect(probe.ips.toSet(), hasLength(252));
    });

    test('two subnets are both swept', () async {
      final probe = ScriptedProbe();
      final r = await scannerFor(
        [iface('192.168.1.5'), iface('10.20.30.4', name: 'eth0')],
        RecordingSink(),
        probe.call,
      ).scan();
      expect(r.probed, 506);
      expect(probe.ips.where((i) => i.startsWith('10.20.30.')), hasLength(253));
    });

    test('onlyInterface restricts the sweep to that interface', () async {
      final probe = ScriptedProbe();
      final r = await scannerFor(
        [iface('192.168.1.5'), iface('10.20.30.4', name: 'eth0')],
        RecordingSink(),
        probe.call,
      ).scan(onlyInterface: 'eth0');
      expect(r.probed, 253);
      expect(probe.ips.every((i) => i.startsWith('10.20.30.')), isTrue);
      final none = await scannerFor(
        [iface('192.168.1.5')],
        RecordingSink(),
        ScriptedProbe().call,
      ).scan(onlyInterface: 'nope0');
      expect(none.probed, 0);
    });

    test('total probes per scan are capped (default 4096)', () async {
      final probe = ScriptedProbe();
      // 20 distinct /24s = 5060 candidates.
      final ifaces = [
        for (var i = 0; i < 20; i++) iface('10.0.$i.1', name: 'v$i'),
      ];
      final r = await scannerFor(ifaces, RecordingSink(), probe.call).scan();
      expect(r.probed, 4096);
      expect(probe.ips, hasLength(4096));
      expect(probe.ips.toSet(), hasLength(4096));
    });

    test('maxProbes is configurable', () async {
      final probe = ScriptedProbe();
      final r = await scannerFor(
        [iface('10.0.0.1')],
        RecordingSink(),
        probe.call,
        maxProbes: 100,
      ).scan();
      expect(r.probed, 100);
      expect(probe.ips, hasLength(100));
    });

    test(
      'no interfaces, or a failing provider: empty result, no throw',
      () async {
        final empty = await scannerFor(
          [],
          RecordingSink(),
          ScriptedProbe().call,
        ).scan();
        expect(empty.probed, 0);
        expect(empty.found, isEmpty);

        final bad = FakeIfaces([iface('10.0.0.2')])..failWith = StateError('x');
        final r = await SubnetScanner(
          ifaces: bad,
          sink: RecordingSink(),
          probe: ScriptedProbe().call,
        ).scan();
        expect(r.probed, 0);
      },
    );

    test('constructor rejects nonsense limits', () {
      Object build({int concurrency = 1, int maxProbes = 1}) => SubnetScanner(
        ifaces: FakeIfaces([]),
        sink: RecordingSink(),
        concurrency: concurrency,
        maxProbes: maxProbes,
      );
      expect(() => build(concurrency: 0), throwsArgumentError);
      expect(() => build(maxProbes: 0), throwsArgumentError);
    });
  });

  group('SubnetScanner - concurrency, timing, reporting', () {
    test(
      'never more than `concurrency` probes in flight - and uses all',
      () async {
        for (final c in [1, 7, 64]) {
          final probe = ScriptedProbe()
            ..delay = const Duration(milliseconds: 5);
          final r = await scannerFor(
            [iface('192.168.1.5')],
            RecordingSink(),
            probe.call,
            concurrency: c,
          ).scan();
          expect(r.probed, 253);
          expect(probe.peak, c, reason: 'exactly $c workers, not 253 futures');
          expect(probe.inFlight, 0);
        }
      },
    );

    test('fewer hosts than workers: only as many as hosts', () async {
      final probe = ScriptedProbe()..delay = const Duration(milliseconds: 5);
      await scannerFor(
        [iface('192.168.1.5')],
        RecordingSink(),
        probe.call,
        concurrency: 500,
        maxProbes: 10,
      ).scan();
      expect(probe.peak, 10);
    });

    test(
      'found devices are reported while the scan is still running',
      () async {
        final sink = RecordingSink();
        final gate = Completer<void>();
        final probe = ScriptedProbe({
          '192.168.1.2': device('fast'),
          '192.168.1.200': device('slow'),
        });
        Future<DeviceInfo?> gated(String ip, int port, Duration t) async {
          if (ip == '192.168.1.200') await gate.future;
          return probe.call(ip, port, t);
        }

        var done = false;
        final scan = scannerFor([iface('192.168.1.5')], sink, gated).scan()
          ..whenComplete(() => done = true).ignore();
        await sink.nextSeen();
        expect(sink.seen_.map((s) => s.info.deviceId), ['fast']);
        expect(done, isFalse, reason: 'reported before the sweep finished');
        gate.complete();
        final r = await scan;
        expect(r.found.map((d) => d.deviceId), ['fast', 'slow']);
        expect(sink.seen_.map((s) => s.address), [
          '192.168.1.2',
          '192.168.1.200',
        ]);
      },
    );

    test(
      'a probe that hangs forever is cut off at timeout (+ small grace)',
      () async {
        final calls = <Duration>[];
        Future<DeviceInfo?> hang(String ip, int port, Duration t) {
          calls.add(t);
          return Completer<DeviceInfo?>().future;
        }

        final sw = Stopwatch()..start();
        final r = await scannerFor(
          [iface('192.168.1.5')],
          RecordingSink(),
          hang,
          timeout: const Duration(milliseconds: 40),
          maxProbes: 64,
        ).scan();
        expect(r.probed, 64);
        expect(r.found, isEmpty);
        expect(calls.toSet(), {const Duration(milliseconds: 40)});
        expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      },
    );

    test('a throwing probe counts as "nothing there"', () async {
      final sink = RecordingSink();
      Future<DeviceInfo?> flaky(String ip, int port, Duration t) async {
        if (ip.endsWith('.3')) throw const SocketException('boom');
        if (ip.endsWith('.4')) throw StateError('bug');
        return ip.endsWith('.9') ? device('nine') : null;
      }

      final r = await scannerFor([iface('192.168.1.5')], sink, flaky).scan();
      expect(r.probed, 253);
      expect(r.found.single.deviceId, 'nine');
    });

    test('a throwing sink does not abort the sweep', () async {
      final sink = RecordingSink()..onSeen = (_) => throw StateError('sink');
      final probe = ScriptedProbe({
        '192.168.1.2': device('a'),
        '192.168.1.3': device('b'),
      });
      final r = await scannerFor(
        [iface('192.168.1.5')],
        sink,
        probe.call,
      ).scan();
      expect(r.found.map((d) => d.deviceId), unorderedEquals(['a', 'b']));
      expect(r.probed, 253);
    });

    test('elapsed comes from the injected clock', () async {
      final r = await scannerFor(
        [iface('192.168.1.5')],
        RecordingSink(),
        ScriptedProbe().call,
        clock: FakeClock(),
        maxProbes: 5,
      ).scan();
      expect(r.elapsed, const Duration(seconds: 3));
    });

    test('a scan started during a scan joins it', () async {
      final probe = ScriptedProbe()..delay = const Duration(milliseconds: 2);
      final s = scannerFor([iface('192.168.1.5')], RecordingSink(), probe.call);
      final a = s.scan();
      final b = s.scan();
      expect(identical(a, b), isTrue);
      await Future.wait([a, b]);
      expect(probe.ips, hasLength(253), reason: 'swept once');
      // ... and a later scan is a fresh sweep.
      final again = await s.scan();
      expect(again.probed, 253);
      expect(probe.ips, hasLength(506));
    });

    test(
      'cancel() ends a running scan early; the scanner is reusable',
      () async {
        final probe = ScriptedProbe()..delay = const Duration(milliseconds: 20);
        final s = scannerFor(
          [iface('192.168.1.5')],
          RecordingSink(),
          probe.call,
          concurrency: 4,
        );
        final scan = s.scan();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        s.cancel();
        final sw = Stopwatch()..start();
        final r = await scan;
        expect(sw.elapsed, lessThan(const Duration(milliseconds: 200)));
        expect(r.probed, lessThan(60));
        expect(r.probed, greaterThan(0));

        probe.ips.clear();
        probe.delay = Duration.zero;
        final next = await s.scan();
        expect(next.probed, 253);
      },
    );
  });

  group('isScannablePrivateAddress', () {
    test('table', () {
      bool ok(String ip, {bool loop = false}) =>
          isScannablePrivateAddress(InternetAddress(ip), allowLoopback: loop);
      expect(ok('10.1.2.3'), isTrue);
      expect(ok('172.16.0.1'), isTrue);
      expect(ok('172.31.0.1'), isTrue);
      expect(ok('192.168.1.1'), isTrue);
      expect(ok('169.254.1.1'), isTrue);
      expect(ok('100.64.0.1'), isTrue);
      expect(ok('100.127.0.1'), isTrue);
      expect(ok('172.32.0.1'), isFalse);
      expect(ok('100.128.0.1'), isFalse);
      expect(ok('8.8.8.8'), isFalse);
      expect(ok('127.0.0.1'), isFalse);
      expect(ok('127.0.0.1', loop: true), isTrue);
      expect(ok('::1'), isFalse);
      expect(ok('fd00::1'), isFalse);
    });
  });

  group('ScanPolicy', () {
    const after = Duration(milliseconds: 40);
    late FakeIfaces ifaces;
    late ScanPolicy policy;
    late List<ScanResult> results;
    late ScriptedProbe probe;

    setUp(() {
      ifaces = FakeIfaces([iface('192.168.1.5')]);
      probe = ScriptedProbe();
      results = [];
      policy = ScanPolicy(
        SubnetScanner(ifaces: ifaces, sink: RecordingSink(), probe: probe.call),
        onScanComplete: results.add,
      );
    });
    tearDown(() => policy.dispose());

    Future<void> settle([int ms = 150]) =>
        Future<void>.delayed(Duration(milliseconds: ms));

    test('default delay is 5 s (spec)', () {
      expect(ScanPolicy.defaultDelay, const Duration(seconds: 5));
    });

    test(
      'fires exactly one scan after the delay when no peers are known',
      () async {
        policy.scheduleIfNoPeers(hasPeers: () => false, after: after);
        expect(policy.isScheduled, isTrue);
        await Future<void>.delayed(after ~/ 2);
        expect(ifaces.listCalls, 0, reason: 'not before the delay');
        await settle();
        expect(ifaces.listCalls, 1);
        expect(results, hasLength(1));
        expect(results.single.probed, 253);
        expect(policy.isScheduled, isFalse);
        await settle();
        expect(ifaces.listCalls, 1, reason: 'one-shot');
      },
    );

    test('does not scan when peers exist at fire time', () async {
      var peers = false;
      policy.scheduleIfNoPeers(hasPeers: () => peers, after: after);
      peers = true; // multicast found someone meanwhile
      await settle();
      expect(ifaces.listCalls, 0);
      expect(results, isEmpty);
    });

    test('does not scan when peers are known from the start', () async {
      policy.scheduleIfNoPeers(hasPeers: () => true, after: after);
      await settle();
      expect(ifaces.listCalls, 0);
    });

    test('scheduling again while pending does not add a second scan', () async {
      policy
        ..scheduleIfNoPeers(hasPeers: () => false, after: after)
        ..scheduleIfNoPeers(hasPeers: () => false, after: after)
        ..scheduleIfNoPeers(hasPeers: () => false, after: after);
      await settle();
      expect(ifaces.listCalls, 1);
    });

    test('can be re-armed after it fired', () async {
      policy.scheduleIfNoPeers(hasPeers: () => false, after: after);
      await settle();
      policy.scheduleIfNoPeers(hasPeers: () => false, after: after);
      await settle();
      expect(ifaces.listCalls, 2);
    });

    test('dispose cancels a pending scan', () async {
      policy.scheduleIfNoPeers(hasPeers: () => false, after: after);
      policy.dispose();
      expect(policy.isScheduled, isFalse);
      await settle();
      expect(ifaces.listCalls, 0);
      // ... and a disposed policy stays inert.
      policy.scheduleIfNoPeers(hasPeers: () => false, after: after);
      await settle();
      expect(ifaces.listCalls, 0);
      policy.dispose(); // twice is fine
    });

    test('dispose cancels the scan the policy started', () async {
      final slow = ScriptedProbe()..delay = const Duration(milliseconds: 20);
      final got = <ScanResult>[];
      final p2 = ScanPolicy(
        SubnetScanner(
          ifaces: ifaces,
          sink: RecordingSink(),
          probe: slow.call,
          concurrency: 2, // 253 hosts would take > 2 s
        ),
        onScanComplete: got.add,
      );
      p2.scheduleIfNoPeers(hasPeers: () => false, after: after);
      await Future<void>.delayed(after + const Duration(milliseconds: 80));
      expect(slow.ips, isNotEmpty, reason: 'scan is under way');
      p2.dispose();
      await settle(300);
      expect(slow.ips.length, lessThan(100));
      expect(slow.inFlight, 0);
      expect(got, hasLength(1), reason: 'the partial result is delivered');
    });

    test(
      'a failing onScanComplete callback does not break the policy',
      () async {
        final p2 = ScanPolicy(
          SubnetScanner(
            ifaces: ifaces,
            sink: RecordingSink(),
            probe: probe.call,
          ),
          onScanComplete: (_) => throw StateError('cb'),
        );
        p2.scheduleIfNoPeers(hasPeers: () => false, after: after);
        await settle();
        expect(ifaces.listCalls, 1);
        p2.dispose();
      },
    );
  });

  group('SubnetScanner with a real ApiServer and the default probe', () {
    late Directory dir;
    late LibreShareEngine engine;
    late int port;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ls_scan_');
      engine = LibreShareEngine(
        self: const DeviceInfo(
          deviceId: 'real-engine-1',
          alias: 'Scan Target',
          platform: 'linux',
        ),
        downloadDir: Directory(p.join(dir.path, 'rx')),
        // Only 127.0.0.1 answers, so exactly one of the 253 hosts is "alive".
        bindAddress: InternetAddress.loopbackIPv4,
        preferredPort: 0,
      );
      port = await engine.start();
    });

    tearDown(() async {
      await engine.dispose(force: true);
      await dir.delete(recursive: true);
    });

    test('finds the engine at 127.0.0.1 from a 127.0.0.X interface', () async {
      final sink = RecordingSink();
      final scanner = SubnetScanner(
        ifaces: FakeIfaces([iface('127.0.0.77', name: 'lo', kind: 'unknown')]),
        sink: sink,
        port: port,
        allowLoopback: true,
        timeout: const Duration(seconds: 2),
      );
      final r = await scanner.scan();
      expect(r.probed, 253);
      expect(r.found, hasLength(1));
      expect(r.found.single.deviceId, 'real-engine-1');
      expect(r.found.single.alias, 'Scan Target');
      expect(sink.seen_, hasLength(1));
      expect(sink.seen_.single.address, '127.0.0.1');
      expect(sink.seen_.single.source, DiscoverySource.subnetScan);
      expect(r.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('nothing found when the port is wrong; no exception', () async {
      final sink = RecordingSink();
      final r = await SubnetScanner(
        ifaces: FakeIfaces([iface('127.0.0.77', name: 'lo')]),
        sink: sink,
        port: port == 65535 ? 65534 : port + 1,
        allowLoopback: true,
        timeout: const Duration(milliseconds: 500),
      ).scan();
      expect(r.found, isEmpty);
      expect(sink.seen_, isEmpty);
    });

    test(
      'defaultInfoProbe answers null for a non-LibreShare listener',
      () async {
        final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        raw.listen((s) {
          s.add('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi'.codeUnits);
          s.close();
        });
        addTearDown(() => raw.close());
        expect(
          await defaultInfoProbe(
            '127.0.0.1',
            raw.port,
            const Duration(seconds: 1),
          ),
          isNull,
        );
        expect(
          await defaultInfoProbe('127.0.0.1', port, const Duration(seconds: 1)),
          isA<DeviceInfo>().having((d) => d.deviceId, 'id', 'real-engine-1'),
        );
      },
    );
  });
}
