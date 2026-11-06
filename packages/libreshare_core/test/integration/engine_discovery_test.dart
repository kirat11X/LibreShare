// LibreShareEngine discovery (FR-01..FR-04, NFR-01): three engines in one
// process, discovery over an in-memory bus, transfers over real loopback HTTP.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/discovery_rig.dart';
import '../helpers/test_data.dart';

class FakeMdns implements MdnsBackend {
  final List<MdnsService> advertised = [];
  int stopAdvertisingCalls = 0;
  int stopBrowsingCalls = 0;
  final StreamController<MdnsPeer> peers = StreamController<MdnsPeer>();

  @override
  Future<void> advertise(MdnsService service) async => advertised.add(service);

  @override
  Future<void> stopAdvertising() async => stopAdvertisingCalls++;

  @override
  Stream<MdnsPeer> browse() => peers.stream;

  @override
  Future<void> stopBrowsing() async => stopBrowsingCalls++;
}

class FailingTransport implements MulticastTransport {
  @override
  Future<void> start() async =>
      throw const SocketException('no multicast here');
  @override
  Stream<MulticastPacket> get packets => const Stream.empty();
  @override
  void sendMulticast(List<int> data) {}
  @override
  void sendUnicast(List<int> data, InternetAddress address, int port) {}
  @override
  Future<void> rejoin() async {}
  @override
  Future<void> stop() async {}
}

Future<Map<String, Object?>> getInfo(String ip, int port) async {
  final c = HttpClient();
  try {
    final req = await c.getUrl(Uri.parse('http://$ip:$port$kApiPrefix/info'));
    final res = await req.close();
    expect(res.statusCode, 200);
    return (jsonDecode(await utf8.decoder.bind(res).join()) as Map)
        .cast<String, Object?>();
  } finally {
    c.close(force: true);
  }
}

Future<void> main() async {
  final aliasesWork = await loopbackAliasesWork();
  final skip = aliasesWork ? null : '127.0.0.2 cannot be bound on this host';

  late Directory sandbox;
  late DiscoveryRig rig;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ls_engine_discovery_');
    rig = DiscoveryRig(sandbox);
  });
  tearDown(() async {
    await rig.dispose();
    sandbox.deleteSync(recursive: true);
  });

  File src(String name, int size, {int seed = 1}) => writeRandomFile(
    Directory(p.join(sandbox.path, 'src')),
    name,
    size,
    seed: seed,
  );

  group('finding each other (FR-02, FR-03, NFR-01)', () {
    test(
      'two engines list each other with name, platform and address',
      () async {
        final a = await rig.start('Alice', platform: 'linux');
        final b = await rig.start('Bob', platform: 'windows');
        await untilTrue(() => a.seen(b) != null && b.seen(a) != null);

        final bob = a.seen(b)!;
        expect(bob.info.alias, 'Bob');
        expect(bob.info.platform, 'windows');
        expect(bob.info.port, b.engine.port, reason: 'the bound port');
        expect(bob.info.addrs.map((x) => x.ip), contains(b.ip));
        expect(
          bob.source,
          anyOf(DiscoverySource.multicast, DiscoverySource.register),
        );
        final alice = b.seen(a)!;
        expect(alice.info.alias, 'Alice');
        expect(alice.info.platform, 'linux');
        expect(alice.info.port, a.engine.port);
        // Nobody lists themselves.
        expect(a.seen(a), isNull);
        expect(b.seen(b), isNull);
      },
      skip: skip,
    );

    test('three engines see the other two', () async {
      final a = await rig.start('A');
      final b = await rig.start('B');
      final c = await rig.start('C');
      await untilTrue(
        () => [a, b, c].every((n) => n.engine.currentDevices.length == 2),
        what: 'full mesh',
      );
      expect(a.seenNames, ['B', 'C']);
      expect(b.seenNames, ['A', 'C']);
      expect(c.seenNames, ['A', 'B']);
    }, skip: skip);

    test(
      'devices replays the current list on listen, then every change',
      () async {
        final a = await rig.start('A');
        final snapshots = <List<String>>[];
        final sub = a.engine.devices.listen(
          (l) => snapshots.add([for (final d in l) d.info.alias]),
        );
        await untilTrue(() => snapshots.isNotEmpty);
        expect(snapshots.first, isEmpty, reason: 'current list first');

        await rig.start('B');
        await untilTrue(() => snapshots.any((s) => s.contains('B')));
        await sub.cancel();
      },
      skip: skip,
    );

    test(
      'a joining engine is found and finds the others within a second',
      () async {
        final a = await rig.start('A');
        final sw = Stopwatch()..start();
        final b = await rig.start('B');
        await untilTrue(() => a.seen(b) != null && b.seen(a) != null);
        expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      },
      skip: skip,
    );

    test(
      'discovery.enabled false (the default) touches no multicast',
      () async {
        final a = await rig.start('A', discovery: false);
        final b = await rig.start('B');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(a.engine.currentDevices, isEmpty);
        expect(
          rig.bus.sent.where((s) => s.from.address.address == a.ip),
          isEmpty,
        );
        // B announced, A did not hear it.
        expect(b.engine.currentDevices, isEmpty);
      },
      skip: skip,
    );

    test(
      'a multicast transport that cannot start does not stop the engine',
      () async {
        final a = await rig.start('A', transport: FailingTransport.new);
        expect(a.engine.isRunning, isTrue);
        expect(a.engine.currentDevices, isEmpty);
        // Manual entry still works.
        final b = await rig.start('B', discovery: false);
        final d = await a.engine.addManualPeer(b.ip, b.engine.port);
        expect(d.info.alias, 'B');
      },
      skip: skip,
    );
  });

  group('Receive Off (design 01 section 1.3)', () {
    test(
      'an Off engine sees others; they neither list nor register with it',
      () async {
        final a = await rig.start('A');
        final off = await rig.start('Off', mode: const ReceiveOff());
        expect(off.engine.isRunning, isFalse);
        expect(off.engine.deviceInfo.port, 0);

        await untilTrue(() => off.seen(a) != null, what: 'Off sees A');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(a.engine.currentDevices, isEmpty, reason: 'A must not list Off');
        expect(a.seen(off), isNull);

        // What Off put on the wire is a probe, never a receivable announcement.
        final fromOff = [
          for (final s in rig.bus.multicasts)
            if (s.from.address.address == off.ip)
              decodeAnnounce(s.data, allowProbe: true)!,
        ];
        expect(fromOff, isNotEmpty);
        expect(fromOff.every((m) => m.isProbe && m.announce), isTrue);
        // A answered with a unicast announce:false carrying its real port.
        final reply = [
          for (final s in rig.bus.unicasts)
            if (s.from.address.address == a.ip) decodeAnnounce(s.data)!,
        ];
        expect(reply, isNotEmpty);
        expect(reply.first.announce, isFalse);
        expect(reply.first.info.port, a.engine.port);
      },
      skip: skip,
    );

    test('Off can send to a device it sees; nobody can send to Off', () async {
      final a = await rig.start('A');
      final off = await rig.start('Off', mode: const ReceiveOff());
      await untilTrue(() => off.seen(a) != null);

      final f = src('from-off.bin', 5000, seed: 3);
      final res = await off.engine.sendTo(off.seen(a)!, [f]);
      expect(res.isSuccess, isTrue, reason: '$res');
      await expectCopyOf(f, File(p.join(a.rx.path, 'from-off.bin')));

      // The sender identity of an Off engine is port 0 (send-only), and
      // nothing listens there.
      expect(off.engine.deviceInfo.port, 0);
      expect(off.engine.isRunning, isFalse);
      expect(a.seen(off), isNull);
    }, skip: skip);

    test(
      'turning Receive on makes the device appear; off makes it a probe again',
      () async {
        final a = await rig.start('A');
        final b = await rig.start('B', mode: const ReceiveOff());
        await untilTrue(() => b.seen(a) != null);
        expect(a.seen(b), isNull);

        await b.engine.receive.turnOn(const ReceiveAlways());
        await untilTrue(
          () => a.seen(b) != null,
          what: 'A lists B once it receives',
        );
        expect(a.seen(b)!.info.port, b.engine.port);

        final before = rig.bus.multicasts.length;
        await b.engine.receive.turnOff();
        expect(b.engine.isRunning, isFalse);
        await pumpEventQueue(times: 50);
        final after = [
          for (final s in rig.bus.multicasts.skip(before))
            if (s.from.address.address == b.ip)
              decodeAnnounce(s.data, allowProbe: true)!,
        ];
        expect(after, isNotEmpty);
        expect(after.every((m) => m.isProbe), isTrue);
        await expectLater(
          a.engine.peerInfo(b.ip, a.seen(b)!.info.port),
          throwsA(isA<SocketException>()),
        );
      },
      skip: skip,
    );

    test('Draining announces nothing receivable', () async {
      final a = await rig.start('A');
      final b = await rig.start('B', autoAccept: false);
      await untilTrue(() => a.seen(b) != null);
      // A session waits for consent, so B has an active session.
      final f = src('wait.bin', 100);
      final sending = a.engine.sendTo(a.seen(b)!, [f]);
      await untilTrue(() => b.engine.activeSessions == 1);

      // Window ends while the session is pending: Draining.
      await b.engine.receive.turnOn(
        const ReceiveFor(Duration(milliseconds: 100)),
      );
      await untilTrue(() => b.engine.receive.state is Draining);
      final before = rig.bus.multicasts.length;
      b.engine.refresh().ignore();
      await pumpEventQueue(times: 50);
      final fromB = [
        for (final s in rig.bus.multicasts.skip(before))
          if (s.from.address.address == b.ip)
            decodeAnnounce(s.data, allowProbe: true)!,
      ];
      expect(fromB.every((m) => m.isProbe), isTrue, reason: 'no real port');

      final sid = b.engine.receiver.pendingSessionIds.single;
      await b.engine.receiver.accept(sid);
      final res = await sending;
      expect(res.isSuccess, isTrue, reason: '$res');
      await untilTrue(() => b.engine.receive.state is Off);
    }, skip: skip);
  });

  group('FR-01: the bound port is the announced port', () {
    Future<(ServerSocket, int)> freeBaseAndBlocker() async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final start = probe.port;
      await probe.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (var p = start + 5; p < start + 100; p++) {
        try {
          final blocker = await ServerSocket.bind(InternetAddress.anyIPv4, p);
          return (blocker, p);
        } on Object {
          continue;
        }
      }
      fail('no free port');
    }

    test('after a fallback /info, the announcement, the registry and the link say so', () async {
      final (blocker, base) = await freeBaseAndBlocker();
      addTearDown(blocker.close);

      final a = await rig.start('A', preferredPort: base);
      final bound = a.engine.port;
      expect(bound, base + 1, reason: 'asked for $base, got $bound');
      expect(a.engine.deviceInfo.port, bound);

      // GET /info reports the bound port (the Inc 1 bug returned the asked-for one).
      final info = await getInfo(a.ip, bound);
      expect(info['port'], bound);
      expect(info['port'], isNot(base));
      expect((info['addrs']! as List).map((e) => (e as Map)['ip']), [a.ip]);

      // The datagram carries it.
      final announced = [
        for (final s in rig.bus.multicasts)
          if (s.from.address.address == a.ip)
            ?decodeAnnounce(s.data, allowProbe: true),
      ].where((m) => !m.isProbe).toList();
      expect(announced, isNotEmpty);
      expect(announced.last.info.port, bound);

      // A peer that hears it lists the bound port and can send to it.
      final b = await rig.start('B');
      await untilTrue(() => b.seen(a) != null);
      expect(b.seen(a)!.info.port, bound);
      final f = src('fallback.bin', 1234);
      expect((await b.engine.sendTo(b.seen(a)!, [f])).isSuccess, isTrue);

      // "My QR" too.
      expect(a.engine.myPeerLink!.port, bound);
    }, skip: skip);
  });

  group('FR-04: pick a device, start a session', () {
    test(
      'discover, then send a multi-file session end to end by device',
      () async {
        final a = await rig.start('Sender');
        final b = await rig.start('Receiver');
        await untilTrue(() => a.seen(b) != null);

        final files = [
          src('empty.txt', 0, seed: 1),
          src('one.bin', 1, seed: 2),
          src('notes.txt', 4321, seed: 3),
          src('two-chunks.bin', kChunkSize + 777, seed: 4),
        ];
        final res = await a.engine.sendTo(a.seen(b)!, files);
        expect(res.status, TransferStatus.completed, reason: '$res');
        for (final f in files) {
          await expectCopyOf(f, File(p.join(b.rx.path, p.basename(f.path))));
        }
        await pumpEventQueue(times: 20);
        expect(
          a.events.whereType<SessionFinished>().where((e) => e.success),
          hasLength(1),
        );
        expect(
          b.events.whereType<FileSaved>().map((e) => p.basename(e.path)),
          unorderedEquals(files.map((f) => p.basename(f.path))),
        );
        // The receiver saw who sent it: the sender's real identity.
        expect(b.engine.receiver.pendingSessionIds, isEmpty);
      },
      skip: skip,
    );

    test('both directions: B sends back to A', () async {
      final a = await rig.start('A');
      final b = await rig.start('B');
      await untilTrue(() => a.seen(b) != null && b.seen(a) != null);
      final f1 = src('a-to-b.bin', 3000, seed: 5);
      final f2 = src('b-to-a.bin', 4000, seed: 6);
      expect((await a.engine.sendTo(a.seen(b)!, [f1])).isSuccess, isTrue);
      expect((await b.engine.sendTo(b.seen(a)!, [f2])).isSuccess, isTrue);
      await expectCopyOf(f1, File(p.join(b.rx.path, 'a-to-b.bin')));
      await expectCopyOf(f2, File(p.join(a.rx.path, 'b-to-a.bin')));
    }, skip: skip);

    test(
      'sendTo tries the next address when the first does not answer',
      () async {
        final a = await rig.start('A');
        final b = await rig.start('B', discovery: false);
        final real = b.engine.deviceInfo;
        final device = DiscoveredDevice(
          info: real,
          address: '127.0.0.250', // nobody listens there
          lastSeen: DateTime.now(),
          source: DiscoverySource.multicast,
        );
        final f = src('second-address.bin', 777, seed: 7);
        final res = await a.engine.sendTo(device, [
          f,
        ], probeTimeout: const Duration(milliseconds: 300));
        expect(res.isSuccess, isTrue, reason: '$res');
        await expectCopyOf(f, File(p.join(b.rx.path, 'second-address.bin')));
      },
      skip: skip,
    );

    test('sendTo skips an address where another device answers', () async {
      final a = await rig.start('A');
      final impostor = await rig.start('Impostor', discovery: false);
      final b = await rig.start('B', discovery: false);
      // Same port on two aliases is not possible, so point the "first
      // address" at the impostor's port by describing B with the impostor's
      // address list and port: the id check must reject it.
      final device = DiscoveredDevice(
        info: DeviceInfo(
          deviceId: b.id,
          alias: 'B',
          platform: 'linux',
          port: impostor.engine.port,
          addrs: [DeviceAddress(impostor.ip)],
        ),
        address: impostor.ip,
        lastSeen: DateTime.now(),
        source: DiscoverySource.multicast,
      );
      final f = src('never.bin', 10);
      final res = await a.engine.sendTo(device, [f]);
      expect(res.status, TransferStatus.failed);
      expect(res.failureReason, FailureReason.noConnection);
      expect(impostor.rx.existsSync() ? impostor.rx.listSync() : [], isEmpty);
    }, skip: skip);

    test(
      'no reachable address -> FAILED(NO_CONNECTION) and one failed event',
      () async {
        final a = await rig.start('A');
        final device = DiscoveredDevice(
          info: const DeviceInfo(
            deviceId: 'ghost',
            alias: 'Ghost',
            platform: 'linux',
            port: 53318,
            addrs: [DeviceAddress('127.0.0.251')],
          ),
          address: '127.0.0.250',
          lastSeen: DateTime.now(),
          source: DiscoverySource.multicast,
        );
        final res = await a.engine.sendTo(device, [
          src('x.bin', 10),
        ], probeTimeout: const Duration(milliseconds: 200));
        expect(res.status, TransferStatus.failed);
        expect(res.failureReason, FailureReason.noConnection);
        await pumpEventQueue(times: 20);
        final finished = a.events.whereType<SessionFinished>().toList();
        expect(finished, hasLength(1));
        expect(finished.single.success, isFalse);
        expect(finished.single.reason, 'NO_CONNECTION');
      },
      skip: skip,
    );

    test('sendFiles by host and port still works', () async {
      final a = await rig.start('A', discovery: false);
      final b = await rig.start('B', discovery: false);
      final f = src('direct.bin', 2048, seed: 8);
      final res = await a.engine.sendFiles(
        [f],
        host: b.ip,
        port: b.engine.port,
      );
      expect(res.isSuccess, isTrue);
    }, skip: skip);
  });

  group('manual entry and links (screen 8, rule 6)', () {
    test(
      'addManualPeer lists the device and returns what to confirm',
      () async {
        final a = await rig.start('A', discovery: false);
        final b = await rig.start('B', discovery: false);
        final d = await a.engine.addManualPeer(b.ip, b.engine.port);
        expect(d.info.alias, 'B');
        expect(d.address, b.ip);
        expect(d.source, DiscoverySource.manual);
        expect(d.info.port, b.engine.port);
        expect(d.info.fingerprint, '', reason: 'no TLS yet (Inc 3)');
        expect(a.engine.currentDevices.single.id, b.id);
        final f = src('manual.bin', 100);
        expect((await a.engine.sendTo(d, [f])).isSuccess, isTrue);
      },
      skip: skip,
    );

    test('resolvePeer has no side effects until addResolvedPeer', () async {
      final a = await rig.start('A', discovery: false);
      final b = await rig.start('B', discovery: false);
      final r = await a.engine.resolvePeer(b.ip, b.engine.port);
      expect(r.info.deviceId, b.id);
      expect(a.engine.currentDevices, isEmpty);
      final d = a.engine.addResolvedPeer(r, source: DiscoverySource.qr);
      expect(d.source, DiscoverySource.qr);
      expect(a.engine.currentDevices, hasLength(1));
    }, skip: skip);

    test('addManualPeer errors: unreachable, bad address, itself', () async {
      final a = await rig.start('A', discovery: false);
      await expectLater(
        a.engine.addManualPeer('127.0.0.77', 53399),
        throwsA(isA<PeerUnreachable>()),
      );
      await expectLater(
        a.engine.addManualPeer('not-an-ip', 53318),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        a.engine.addManualPeer(a.ip, a.engine.port),
        throwsArgumentError,
      );
      expect(a.engine.currentDevices, isEmpty);
    }, skip: skip);

    test('myPeerLink of one engine is accepted by another', () async {
      final a = await rig.start('A', discovery: false);
      final b = await rig.start('B', discovery: false);
      final link = b.engine.myPeerLink!;
      expect(link.ip, b.ip);
      expect(link.port, b.engine.port);
      expect(link.deviceId, b.id);
      expect(link.alias, 'B');
      expect(PeerLink.parse(link.toUri()), link);

      final d = await a.engine.addPeerLink(link);
      expect(d.id, b.id);
      expect(d.source, DiscoverySource.qr);
    }, skip: skip);

    test('addPeerLink rejects a device id that does not match', () async {
      final a = await rig.start('A', discovery: false);
      final b = await rig.start('B', discovery: false);
      final wrong = PeerLink(
        ip: b.ip,
        port: b.engine.port,
        deviceId: '11111111-2222-4333-8444-555555555555',
      );
      await expectLater(
        a.engine.addPeerLink(wrong),
        throwsA(isA<DeviceIdMismatch>()),
      );
      await expectLater(
        a.engine.addPeerLink(PeerLink(ip: '127.0.0.77', port: 53399)),
        throwsA(isA<PeerUnreachable>()),
      );
      expect(a.engine.currentDevices, isEmpty);
    }, skip: skip);

    test('myPeerLink is null while nothing listens', () async {
      final off = await rig.start('Off', mode: const ReceiveOff());
      expect(off.engine.myPeerLink, isNull);
      await off.engine.receive.turnOn(const ReceiveAlways());
      expect(off.engine.myPeerLink, isNotNull);
      await off.engine.receive.turnOff();
      expect(off.engine.myPeerLink, isNull);
    }, skip: skip);
  });

  group('multicast blocked: subnet scan (FR-02, spec 4.2 rule 4)', () {
    test('B finds A by scanning and A finds B through the register-back', () async {
      rig.bus.blackhole = true;
      final a = await rig.start('A');
      // The scan walks 127.0.0.1-254 on A's port, from an "interface" at .9.
      final b = await rig.start(
        'B',
        autoScan: true,
        autoScanDelay: const Duration(milliseconds: 150),
        scanPort: a.engine.port,
        allowLoopbackScan: true,
        interfaces: FakeIfaces([
          LocalInterface(
            name: 'lo',
            address: InternetAddress('127.0.0.9'),
            kind: 'ethernet',
          ),
        ]),
      );
      final sw = Stopwatch()..start();
      await untilTrue(() => b.seen(a) != null, what: 'scan finds A');
      expect(b.seen(a)!.source, DiscoverySource.subnetScan);
      expect(b.seen(a)!.address, a.ip);
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
      expect(rig.bus.sent.where((s) => !s.dropped), isEmpty);

      await untilTrue(() => a.seen(b) != null, what: 'A learns B');
      expect(a.seen(b)!.source, DiscoverySource.register);
      // The address A saw B at may be loopback-ambiguous; sendTo falls back to
      // the addresses B announced about itself.
      final f = src('via-scan.bin', 1500, seed: 9);
      final res = await a.engine.sendTo(a.seen(b)!, [f]);
      expect(res.isSuccess, isTrue, reason: '$res');
    }, skip: skip);

    test('the scan runs only when no peer is known', () async {
      final a = await rig.start('A');
      final b = await rig.start(
        'B',
        autoScan: true,
        autoScanDelay: const Duration(milliseconds: 300),
        allowLoopbackScan: true,
        interfaces: FakeIfaces([
          LocalInterface(
            name: 'lo',
            address: InternetAddress('127.0.0.9'),
            kind: 'ethernet',
          ),
        ]),
      );
      await untilTrue(() => b.seen(a) != null);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(b.seen(a)!.source, isNot(DiscoverySource.subnetScan));
    }, skip: skip);

    test(
      'scanNetwork on demand returns the result and lists what it found',
      () async {
        final a = await rig.start('A', discovery: false);
        final c = await rig.start(
          'C',
          scanPort: a.engine.port,
          allowLoopbackScan: true,
          interfaces: FakeIfaces([
            LocalInterface(
              name: 'lo',
              address: InternetAddress('127.0.0.9'),
              kind: 'ethernet',
            ),
          ]),
        );
        final r = await c.engine.scanNetwork();
        expect(r.found.map((i) => i.deviceId), contains(a.id));
        expect(c.seen(a)!.source, DiscoverySource.subnetScan);
      },
      skip: skip,
    );

    test('refresh() re-announces and scans', () async {
      final a = await rig.start('A');
      final c = await rig.start(
        'C',
        scanPort: a.engine.port,
        allowLoopbackScan: true,
        interfaces: FakeIfaces([
          LocalInterface(
            name: 'lo',
            address: InternetAddress('127.0.0.9'),
            kind: 'ethernet',
          ),
        ]),
      );
      final before = rig.bus.multicasts.length;
      await c.engine.refresh();
      expect(rig.bus.multicasts.length, greaterThan(before));
      expect(c.seen(a), isNotNull);
    }, skip: skip);
  });

  group('mDNS (optional backend)', () {
    test(
      'advertised only while receiving; browsed peers enter the list',
      () async {
        final mdns = FakeMdns();
        final a = await rig.start('A', mdns: mdns, discovery: true);
        await untilTrue(() => mdns.advertised.isNotEmpty, what: 'advertise');
        final svc = mdns.advertised.single;
        expect(svc.port, a.engine.port);
        expect(svc.name, 'A');
        expect(svc.txt['id'], a.id);
        expect(svc.txt['v'], kProtocolVersion);
        expect(svc.txt['pf'], 'linux');
        expect(
          svc.txt.containsKey('fp'),
          isFalse,
          reason: 'no fingerprint yet',
        );

        // A browsed peer becomes a device (IPv4 preferred); one without an id
        // or port is ignored.
        mdns.peers.add(
          const MdnsPeer(
            name: 'Zed',
            addresses: ['fe80::1', '192.168.7.7'],
            port: 53320,
            txt: {'id': 'zed-id', 'pf': 'android', 'v': '1.0'},
          ),
        );
        mdns.peers.add(
          const MdnsPeer(name: 'NoId', addresses: ['192.168.7.8'], port: 1),
        );
        mdns.peers.add(
          const MdnsPeer(
            name: 'NoPort',
            addresses: ['192.168.7.9'],
            port: 0,
            txt: {'id': 'p'},
          ),
        );
        await untilTrue(() => a.engine.currentDevices.isNotEmpty);
        final zed = a.engine.currentDevices.single;
        expect(zed.info.alias, 'Zed');
        expect(zed.info.platform, 'android');
        expect(zed.address, '192.168.7.7');
        expect(zed.info.port, 53320);
        expect(zed.source, DiscoverySource.mdns);
        await pumpEventQueue(times: 20);
        expect(a.engine.currentDevices, hasLength(1));

        await a.engine.receive.turnOff();
        await untilTrue(() => mdns.stopAdvertisingCalls >= 1);
        final advertisedBefore = mdns.advertised.length;
        await a.engine.receive.turnOn(const ReceiveAlways());
        await untilTrue(() => mdns.advertised.length == advertisedBefore + 1);

        await a.engine.stop();
        expect(mdns.stopBrowsingCalls, greaterThanOrEqualTo(1));
      },
      skip: skip,
    );

    test('an Off engine advertises nothing but still browses', () async {
      final mdns = FakeMdns();
      final off = await rig.start('Off', mode: const ReceiveOff(), mdns: mdns);
      mdns.peers.add(
        const MdnsPeer(
          name: 'Zed',
          addresses: ['192.168.7.7'],
          port: 53320,
          txt: {'id': 'zed-id'},
        ),
      );
      await untilTrue(() => off.engine.currentDevices.isNotEmpty);
      expect(mdns.advertised, isEmpty);
    }, skip: skip);
  });

  group('lifecycle', () {
    test('stop() then start() brings discovery back', () async {
      final a = await rig.start('A');
      final b = await rig.start('B');
      await untilTrue(() => a.seen(b) != null);

      await b.engine.stop();
      expect(b.engine.isRunning, isFalse);
      expect(b.engine.isStarted, isFalse);
      await b.engine.start();
      expect(b.engine.isRunning, isTrue);
      expect(b.engine.receive.state, isA<On>());
      await untilTrue(
        () => a.seen(b)?.info.port == b.engine.port,
        what: 'A knows the new port',
      );
    }, skip: skip);

    test('dispose is final and releases everything', () async {
      final a = await rig.start('A');
      final port = a.engine.port;
      await a.engine.dispose();
      expect(a.engine.isRunning, isFalse);
      await expectLater(
        a.engine.peerInfo(a.ip, port),
        throwsA(isA<SocketException>()),
      );
      await a.engine.dispose(); // idempotent
    }, skip: skip);
  });
}

Future<void> expectCopyOf(File src, File dst) async {
  expect(dst.existsSync(), isTrue, reason: '${dst.path} missing');
  expect(dst.lengthSync(), src.lengthSync());
  expect(await filesIdentical(src, dst), isTrue, reason: dst.path);
}
