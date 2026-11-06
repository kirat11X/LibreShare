// ApiPeerRegistrar (spec 4.2 rule 2): POST /register to the announcing peer,
// true on 2xx, false on anything else within the timeout, never throws.
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/api_fake_handler.dart';

const DeviceInfo me = DeviceInfo(
  deviceId: 'me-device',
  alias: 'Me',
  platform: 'linux',
  port: 53318,
  addrs: [DeviceAddress('192.168.1.5', iface: 'wifi')],
);

DeviceInfo peerAt(int port, {String id = 'peer-device'}) =>
    DeviceInfo(deviceId: id, alias: 'Peer', platform: 'linux', port: port);

/// Real [ApiClient] that counts `close()` calls.
class SpyClient extends ApiClient {
  SpyClient(String host, int port, {Duration? timeout})
    : super(
        host: host,
        port: port,
        connectTimeout: timeout ?? const Duration(seconds: 3),
        requestTimeout: timeout ?? const Duration(seconds: 30),
      );
  int closes = 0;
  @override
  void close() {
    closes++;
    super.close();
  }
}

/// Client whose register() never completes (or throws).
class StuckClient extends SpyClient {
  StuckClient({this.error}) : super('127.0.0.1', 1);
  final Object? error;
  @override
  Future<DeviceInfo> register(DeviceInfo self) {
    if (error != null) return Future.error(error!);
    return Completer<DeviceInfo>().future;
  }
}

void main() {
  late Directory dir;
  FileReceiver? receiver;
  ApiServer? server;
  late int port;

  Future<void> startReal({DeviceInfo? self}) async {
    final r = receiver = FileReceiver(
      self: self ?? peerAt(0),
      downloadDir: Directory(p.join(dir.path, 'rx')),
    );
    server = ApiServer(
      handler: r,
      bindAddress: InternetAddress.loopbackIPv4,
      preferredPort: 0,
    );
    port = await server!.start();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ls_registrar_');
  });

  tearDown(() async {
    await server?.stop(force: true);
    receiver?.dispose();
    server = null;
    receiver = null;
    await dir.delete(recursive: true);
  });

  test('is usable as the PeerRegistrar typedef', () async {
    await startReal();
    final PeerRegistrar registrar = ApiPeerRegistrar(self: () => me).call;
    expect(await registrar(peerAt(port), '127.0.0.1'), isTrue);
  });

  test('2xx from a real ApiServer + FileReceiver: true', () async {
    await startReal();
    final spy = <SpyClient>[];
    final r = ApiPeerRegistrar(
      self: () => me,
      clientFactory: (host, prt) => SpyClient(host, prt)..also(spy.add),
    );
    expect(await r(peerAt(port), '127.0.0.1'), isTrue);
    expect(spy.single.closes, 1);
  });

  test('POSTs our DeviceInfo to the peer\'s announced port', () async {
    final fake = FakeIncomingHandler();
    server = ApiServer(
      handler: fake,
      bindAddress: InternetAddress.loopbackIPv4,
      preferredPort: 0,
    );
    port = await server!.start();

    String? gotHost;
    int? gotPort;
    final r = ApiPeerRegistrar(
      self: () => me,
      clientFactory: (host, prt) {
        gotHost = host;
        gotPort = prt;
        return ApiClient(host: host, port: prt);
      },
    );
    // The default port 53318 is NOT where the peer listens.
    expect(await r(peerAt(port), '127.0.0.1'), isTrue);
    expect(gotHost, '127.0.0.1');
    expect(gotPort, port);
    expect(fake.calls, ['register']);
    expect(fake.lastRegistered?.deviceId, 'me-device');
    expect(fake.lastRegistered?.alias, 'Me');
    expect(fake.lastRegistered?.addrs.single.ip, '192.168.1.5');
  });

  test('self is evaluated per call (fresh addresses / alias)', () async {
    final fake = FakeIncomingHandler();
    server = ApiServer(
      handler: fake,
      bindAddress: InternetAddress.loopbackIPv4,
      preferredPort: 0,
    );
    port = await server!.start();
    var alias = 'one';
    final r = ApiPeerRegistrar(
      self: () => DeviceInfo(deviceId: 'x', alias: alias, platform: 'linux'),
    );
    await r(peerAt(port), '127.0.0.1');
    expect(fake.lastRegistered?.alias, 'one');
    alias = 'two';
    await r(peerAt(port), '127.0.0.1');
    expect(fake.lastRegistered?.alias, 'two');
  });

  group('false, never an exception', () {
    test('server answers 4xx (426: unsupported protocol major)', () async {
      await startReal();
      final spy = <SpyClient>[];
      final r = ApiPeerRegistrar(
        self: () => DeviceInfo(
          deviceId: 'x',
          alias: 'Future',
          platform: 'linux',
          version: '2.0',
        ),
        clientFactory: (h, prt) => SpyClient(h, prt)..also(spy.add),
      );
      expect(await r(peerAt(port), '127.0.0.1'), isFalse);
      expect(spy.single.closes, 1);
    });

    test('server answers 400 via the handler', () async {
      final fake = FakeIncomingHandler()
        ..onRegister = (_) => throw LsException(LsErrorCode.badRequest, 'no');
      server = ApiServer(
        handler: fake,
        bindAddress: InternetAddress.loopbackIPv4,
        preferredPort: 0,
      );
      port = await server!.start();
      expect(
        await ApiPeerRegistrar(self: () => me)(peerAt(port), '127.0.0.1'),
        isFalse,
      );
    });

    test('server answers 500', () async {
      final fake = FakeIncomingHandler()
        ..onRegister = (_) => throw StateError('kaboom');
      server = ApiServer(
        handler: fake,
        bindAddress: InternetAddress.loopbackIPv4,
        preferredPort: 0,
      );
      port = await server!.start();
      expect(
        await ApiPeerRegistrar(self: () => me)(peerAt(port), '127.0.0.1'),
        isFalse,
      );
    });

    test('nothing listening: connection refused', () async {
      await startReal();
      final closed = port;
      await server!.stop(force: true);
      final sw = Stopwatch()..start();
      expect(
        await ApiPeerRegistrar(self: () => me)(peerAt(closed), '127.0.0.1'),
        isFalse,
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test(
      'peer accepts the connection but never answers: false at timeout',
      () async {
        await startReal();
        final mute = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final conns = <Socket>[];
        mute.listen(conns.add);
        addTearDown(() async {
          for (final c in conns) {
            c.destroy();
          }
          await mute.close();
        });
        const timeout = Duration(milliseconds: 300);
        final spy = <SpyClient>[];
        final r = ApiPeerRegistrar(
          self: () => me,
          timeout: timeout,
          clientFactory: (h, prt) =>
              SpyClient(h, prt, timeout: const Duration(minutes: 5))
                ..also(spy.add),
        );
        final sw = Stopwatch()..start();
        expect(await r(peerAt(mute.port), '127.0.0.1'), isFalse);
        expect(sw.elapsed, greaterThanOrEqualTo(timeout));
        expect(
          sw.elapsed,
          lessThan(timeout + const Duration(milliseconds: 1500)),
          reason: 'the registrar enforces the timeout itself',
        );
        expect(spy.single.closes, 1);
      },
    );

    test(
      'default timeout is 2 s (spec) and is applied to the default client',
      () async {
        await startReal();
        final mute = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final conns = <Socket>[]; // keep them referenced: GC would close them
        mute.listen(conns.add);
        addTearDown(() async {
          for (final c in conns) {
            c.destroy();
          }
          await mute.close();
        });
        final sw = Stopwatch()..start();
        expect(
          await ApiPeerRegistrar(self: () => me)(
            peerAt(mute.port),
            '127.0.0.1',
          ),
          isFalse,
        );
        expect(sw.elapsed, greaterThanOrEqualTo(const Duration(seconds: 2)));
        expect(sw.elapsed, lessThan(const Duration(milliseconds: 3500)));
      },
    );

    test('garbage answer from a non-LibreShare listener', () async {
      await startReal();
      final junk = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      junk.listen((s) {
        s.add('HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nnope'.codeUnits);
        s.close();
      });
      addTearDown(() => junk.close());
      expect(
        await ApiPeerRegistrar(self: () => me)(peerAt(junk.port), '127.0.0.1'),
        isFalse,
      );
    });

    test('client factory throws / register throws / self throws', () async {
      await startReal();
      expect(
        await ApiPeerRegistrar(
          self: () => me,
          clientFactory: (h, prt) => throw StateError('factory'),
        )(peerAt(port), '127.0.0.1'),
        isFalse,
      );

      final stuck = StuckClient(error: const SocketException('x'));
      expect(
        await ApiPeerRegistrar(
          self: () => me,
          clientFactory: (h, prt) => stuck,
        )(peerAt(port), '127.0.0.1'),
        isFalse,
      );
      expect(stuck.closes, 1);

      final spy = SpyClient('127.0.0.1', port);
      expect(
        await ApiPeerRegistrar(
          self: () => throw StateError('self'),
          clientFactory: (h, prt) => spy,
        )(peerAt(port), '127.0.0.1'),
        isFalse,
      );
      expect(spy.closes, lessThanOrEqualTo(1));
    });

    test('invalid address or port: false without opening a client', () async {
      var created = 0;
      final r = ApiPeerRegistrar(
        self: () => me,
        clientFactory: (h, prt) {
          created++;
          return ApiClient(host: h, port: prt);
        },
      );
      expect(await r(peerAt(1234), 'evil.example.com'), isFalse);
      expect(await r(peerAt(1234), '127.0.0.1/../x'), isFalse);
      expect(await r(peerAt(1234), ''), isFalse);
      expect(await r(peerAt(0), '127.0.0.1'), isFalse);
      expect(await r(peerAt(70000), '127.0.0.1'), isFalse);
      expect(created, 0);
    });
  });

  test('the client is closed on every path (once)', () async {
    await startReal();
    final created = <SpyClient>[];
    ApiPeerRegistrar make({
      Duration timeout = const Duration(milliseconds: 100),
    }) => ApiPeerRegistrar(
      self: () => me,
      timeout: timeout,
      clientFactory: (h, prt) {
        final c = h == '127.0.0.1' && prt == 1
            ? StuckClient()
            : SpyClient(h, prt);
        created.add(c);
        return c;
      },
    );

    await make(timeout: const Duration(seconds: 2))(
      peerAt(port),
      '127.0.0.1',
    ); // success
    await make()(peerAt(1), '127.0.0.1'); // stuck -> timeout path
    await make()(peerAt(65000), '127.0.0.1'); // refused
    expect(created, hasLength(3));
    expect(created.map((c) => c.closes), everyElement(1));
  });

  test(
    'https flag reaches the default client (plain server refuses TLS)',
    () async {
      await startReal();
      final r = ApiPeerRegistrar(self: () => me, https: true);
      expect(await r(peerAt(port), '127.0.0.1'), isFalse);
    },
  );
}

extension<T> on T {
  void also(void Function(T) f) => f(this);
}
