// FR-01: the engine binds 53318 and falls back to the next free port; the port
// it reports (GET /info, POST /register, deviceInfo) is the one it really
// bound, and the addresses are the real local ones. Inc 1 returned the port it
// was asked for.
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/discovery_rig.dart';
import '../helpers/port_blocker.dart';

const _loop = '127.0.0.1';

Future<Map<String, Object?>> _get(int port, String path) async {
  final c = HttpClient();
  try {
    final req = await c.getUrl(
      Uri.parse('http://$_loop:$port$kApiPrefix$path'),
    );
    final res = await req.close();
    expect(res.statusCode, 200, reason: path);
    return (jsonDecode(await utf8.decoder.bind(res).join()) as Map)
        .cast<String, Object?>();
  } finally {
    c.close(force: true);
  }
}

Future<Map<String, Object?>> _register(int port, DeviceInfo me) async {
  final c = HttpClient();
  try {
    final req = await c.postUrl(
      Uri.parse('http://$_loop:$port$kApiPrefix/register'),
    );
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(me.toJson()));
    final res = await req.close();
    expect(res.statusCode, 200);
    return (jsonDecode(await utf8.decoder.bind(res).join()) as Map)
        .cast<String, Object?>();
  } finally {
    c.close(force: true);
  }
}

void main() {
  late Directory tmp;
  final engines = <LibreShareEngine>[];

  LibreShareEngine engine(
    String name, {
    int preferredPort = 0,
    InternetAddress? bind,
    DiscoveryConfig discovery = DiscoveryConfig.disabled,
    ReceiveConfig receiveConfig = const ReceiveConfig(),
  }) {
    final e = LibreShareEngine(
      self: DeviceInfo(
        deviceId: 'id-$name',
        alias: name,
        platform: 'linux',
        port: 12345, // ignored: the bound port is what counts
      ),
      downloadDir: Directory(p.join(tmp.path, 'rx-$name')),
      preferredPort: preferredPort,
      bindAddress: bind ?? InternetAddress.loopbackIPv4,
      enableRateLimit: false,
      discovery: discovery,
      receiveConfig: receiveConfig,
    );
    engines.add(e);
    return e;
  }

  /// A base port P such that P..P+2 can be bound right now.
  Future<int> freeBase() async {
    final base = PortBlocker.findFreeRun(3);
    if (base != null) return base;
    fail('no run of free ports');
  }

  setUp(() => tmp = Directory.systemTemp.createTempSync('ls_startup_'));
  tearDown(() async {
    for (final e in engines) {
      await e.dispose(force: true);
    }
    engines.clear();
    tmp.deleteSync(recursive: true);
  });

  test(
    'a default engine listens after start() and reports the bound port',
    () async {
      final e = engine('plain');
      expect(e.deviceInfo.port, 0, reason: 'nothing bound yet');
      final port = await e.start();
      expect(port, greaterThan(0));
      expect(e.port, port);
      expect(e.isRunning, isTrue);
      expect(e.receive.state, isA<On>());
      expect(e.deviceInfo.port, port);
      expect((await _get(port, '/info'))['port'], port);
    },
  );

  test('FR-01: GET /info reports the port bound after a fallback, not the one asked for', () async {
    final base = await freeBase();
    final blocker = PortBlocker.bind(base);
    addTearDown(blocker.close);

    final e = engine('fallback', preferredPort: base);
    final port = await e.start();
    expect(port, base + 1);
    final info = await _get(port, '/info');
    expect(info['port'], base + 1);
    expect(info['port'], isNot(base));
    expect(info['port'], isNot(12345), reason: 'not the template either');
    expect(info['alias'], 'fallback');
    expect(e.deviceInfo.port, base + 1);
    expect(e.myPeerLink!.port, base + 1, reason: 'My QR carries it too');
  });

  test('two engines asking for the same port report their own', () async {
    final base = await freeBase();
    final a = engine('a', preferredPort: base);
    final b = engine('b', preferredPort: base);
    expect(await a.start(), base);
    expect(await b.start(), base + 1);
    expect((await _get(base, '/info'))['alias'], 'a');
    expect((await _get(base, '/info'))['port'], base);
    expect((await _get(base + 1, '/info'))['alias'], 'b');
    expect((await _get(base + 1, '/info'))['port'], base + 1);
  });

  test('POST /register answers with the bound port too', () async {
    final base = await freeBase();
    final blocker = PortBlocker.bind(base);
    addTearDown(blocker.close);
    final e = engine('reg', preferredPort: base);
    final port = await e.start();
    final answer = await _register(
      port,
      const DeviceInfo(deviceId: 'peer', alias: 'peer', platform: 'linux'),
    );
    expect(answer['port'], port);
    expect(answer['deviceId'], 'id-reg');
  });

  test(
    'addrs are the local non-loopback addresses (or the pinned bind address)',
    () async {
      final fake = FakeIfaces([
        LocalInterface(
          name: 'wlan0',
          address: InternetAddress('192.168.1.5'),
          kind: 'wifi',
        ),
        LocalInterface(
          name: 'eth0',
          address: InternetAddress('10.0.0.8'),
          kind: 'ethernet',
        ),
        LocalInterface(
          name: 'lo',
          address: InternetAddress('127.0.0.1'),
          kind: 'unknown',
        ),
      ]);
      // Listening on all interfaces: the enumerated ones, loopback left out.
      final all = engine(
        'all',
        bind: InternetAddress.anyIPv4,
        discovery: DiscoveryConfig(enabled: false, interfaces: fake),
      );
      final port = await all.start();
      final info = DeviceInfo.fromJson(await _get(port, '/info'));
      expect(info.addrs.map((a) => (a.ip, a.iface)), [
        ('192.168.1.5', 'wifi'),
        ('10.0.0.8', 'ethernet'),
      ]);
      expect(all.myPeerLink!.ip, '192.168.1.5', reason: 'wifi preferred');
      expect(all.myPeerLink!.port, port);

      // Pinned to one address: that address.
      final pinned = engine('pinned');
      final pp = await pinned.start();
      final pinnedInfo = DeviceInfo.fromJson(await _get(pp, '/info'));
      expect(pinnedInfo.addrs.map((a) => a.ip), [_loop]);
    },
  );

  test(
    'Receive Off: start() returns 0, no listener, port 0 in deviceInfo',
    () async {
      final e = engine(
        'off',
        receiveConfig: const ReceiveConfig(initialMode: ReceiveOff()),
      );
      expect(await e.start(), 0);
      expect(e.isStarted, isTrue);
      expect(e.isRunning, isFalse);
      expect(e.receive.state, const Off(OffReason.neverEnabled));
      expect(e.deviceInfo.port, 0);
      expect(() => e.port, throwsStateError);
      expect(e.receiver, isNotNull, reason: 'available for outgoing use');

      final port = await _turnOnAndGetPort(e);
      expect((await _get(port, '/info'))['port'], port);
    },
  );

  test(
    'double start and use before start are errors, stop is idempotent',
    () async {
      final e = engine('life');
      expect(() => e.port, throwsStateError);
      expect(() => e.receiver, throwsStateError);
      await e.stop(); // never started: nothing to do
      await e.start();
      await expectLater(e.start(), throwsStateError);
      await e.stop();
      await e.stop();
      expect(e.isStarted, isFalse);
      expect(e.isRunning, isFalse);
      // ...and it can start again.
      final again = await e.start();
      expect((await _get(again, '/info'))['port'], again);
    },
  );
}

Future<int> _turnOnAndGetPort(LibreShareEngine e) async {
  await e.receive.turnOn(const ReceiveAlways());
  return e.port;
}
