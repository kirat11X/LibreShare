// Receive mode on a real engine (design 01 s1.6): the listener really opens and
// closes, windows really expire (system scheduler, short windows), a window
// that ends during a transfer drains, and the stored state survives.
@TestOn('vm')
library;

import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/discovery_rig.dart';
import '../helpers/port_blocker.dart';
import '../helpers/test_data.dart';

const _loop = '127.0.0.1';

/// HTTP status of `GET /info`, or null when the connection is refused.
Future<int?> infoStatus(int port) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final req = await c.getUrl(
      Uri.parse('http://$_loop:$port$kApiPrefix/info'),
    );
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  } on SocketException {
    return null;
  } finally {
    c.close(force: true);
  }
}

void main() {
  late Directory tmp;
  final engines = <LibreShareEngine>[];

  LibreShareEngine engine(
    String name, {
    ReceiveConfig receiveConfig = const ReceiveConfig(),
    bool autoAccept = true,
    int preferredPort = 0,
  }) {
    final e = LibreShareEngine(
      self: DeviceInfo(deviceId: 'id-$name', alias: name, platform: 'linux'),
      downloadDir: Directory(p.join(tmp.path, 'rx-$name')),
      preferredPort: preferredPort,
      autoAccept: autoAccept,
      bindAddress: InternetAddress.loopbackIPv4,
      enableRateLimit: false,
      receiveConfig: receiveConfig,
    );
    engines.add(e);
    return e;
  }

  setUp(() => tmp = Directory.systemTemp.createTempSync('ls_receive_engine_'));
  tearDown(() async {
    for (final e in engines) {
      await e.dispose(force: true);
    }
    engines.clear();
    tmp.deleteSync(recursive: true);
  });

  File src(String name, int size) =>
      writeRandomFile(Directory(p.join(tmp.path, 'src')), name, size);

  test('Off: GET /info refused; On: 200; Off again: refused', () async {
    final e = engine(
      'toggle',
      receiveConfig: const ReceiveConfig(initialMode: ReceiveOff()),
    );
    final states = <ReceiveState>[];
    e.receive.states.listen(states.add);
    expect(await e.start(), 0);

    await e.receive.turnOn(const ReceiveAlways());
    final port = e.port;
    expect(await infoStatus(port), 200);

    await e.receive.turnOff();
    expect(e.isRunning, isFalse);
    expect(await infoStatus(port), isNull, reason: 'connection refused');

    await e.receive.turnOn(const ReceiveAlways());
    expect(await infoStatus(e.port), 200);
    await pumpEventQueue();
    expect(states, [
      const Starting(),
      isA<On>(),
      const Off(OffReason.user),
      const Starting(),
      isA<On>(),
    ]);
  });

  test('a default engine still listens after start() (compat) and Always has no end', () async {
    final e = engine('compat');
    final port = await e.start();
    expect(port, greaterThan(0));
    expect(await infoStatus(port), 200);
    final on = e.receive.state as On;
    expect(on.until, isNull);
    expect(on.visibility, ReceiveVisibility.everyone);
  });

  test(
    'For(N) really expires: listener closed, Off(expired), resume reopens',
    () async {
      final e = engine(
        'window',
        receiveConfig: const ReceiveConfig(
          initialMode: ReceiveFor(Duration(milliseconds: 300)),
        ),
      );
      final port = await e.start();
      expect(await infoStatus(port), 200);

      await e.receive.states.firstWhere((s) => s is Off);
      expect(e.receive.state, const Off(OffReason.expired));
      expect(e.isRunning, isFalse);
      expect(await infoStatus(port), isNull);

      await e.receive.resume();
      expect(e.receive.state, isA<On>());
      expect(await infoStatus(e.port), 200);
    },
  );

  test('a window that ends mid-transfer drains: it completes, the next session is 409 BUSY', () async {
    final rx = engine('drain-rx', autoAccept: false);
    final port = await rx.start();
    final tx = engine(
      'drain-tx',
      receiveConfig: const ReceiveConfig(initialMode: ReceiveOff()),
    );
    await tx.start();

    // A session that waits for consent is an active one.
    final f = src('drain.bin', 5000);
    final sending = tx.sendFiles([f], host: _loop, port: port);
    await untilTrue(() => rx.activeSessions == 1, what: 'pending session');

    await rx.receive.turnOn(const ReceiveFor(Duration(milliseconds: 150)));
    await untilTrue(() => rx.receive.state is Draining, what: 'Draining');
    expect(rx.isRunning, isTrue, reason: 'listener stays for the transfer');

    // A new sender is told to come back later.
    final client = ApiClient(host: _loop, port: port);
    addTearDown(client.close);
    final other = src('other.bin', 10);
    final manifest = const ManifestBuilder();
    final request = manifest.buildSessionRequest(
      sender: tx.deviceInfo,
      files: await manifest.build([other]),
    );
    await expectLater(
      client.createSession(request),
      throwsA(
        isA<LsException>()
            .having((e) => e.code, 'code', LsErrorCode.busy)
            .having((e) => e.httpStatus, 'status', 409)
            .having((e) => e.retryable, 'retryable', isTrue),
      ),
    );

    // The running one is unaffected and finishes.
    await rx.receiver.accept(rx.receiver.pendingSessionIds.single);
    final res = await sending;
    expect(res.isSuccess, isTrue, reason: '$res');
    await untilTrue(() => rx.receive.state is Off, what: 'Off after drain');
    expect(rx.receive.state, const Off(OffReason.expired));
    expect(rx.isRunning, isFalse);
    expect(await infoStatus(port), isNull);
    expect(File(p.join(rx.downloadDir.path, 'drain.bin')).existsSync(), isTrue);
    expect(rx.activeSessions, 0);
  });

  test('Draining gives up at its deadline: the listener closes and the sender does not hang', () async {
    final rx = engine('deadline-rx', autoAccept: false);
    final port = await rx.start();
    final tx = engine(
      'deadline-tx',
      receiveConfig: const ReceiveConfig(initialMode: ReceiveOff()),
    );
    await tx.start();
    final sending = tx.sendFiles(
      [src('d.bin', 100)],
      host: _loop,
      port: port,
      acceptTimeout: const Duration(seconds: 2),
    );
    await untilTrue(() => rx.activeSessions == 1);

    // Same as the controller's real default, only shorter.
    final c = ReceiveController(
      gate: rx,
      store: InMemoryReceiveSettingsStore(),
      clock: const SystemClock(),
      scheduler: const SystemReceiveScheduler(),
      drainGrace: const Duration(milliseconds: 200),
    );
    addTearDown(c.dispose);
    await c.turnOn(const ReceiveFor(Duration(milliseconds: 100)));
    await untilTrue(() => c.state is Off, what: 'forced close');
    expect(rx.isRunning, isFalse);
    expect(await infoStatus(port), isNull);
    await sending; // gives up by itself; no hang
  });

  group('persistence (FileReceiveSettingsStore)', () {
    late FileReceiveSettingsStore store;
    setUp(
      () => store = FileReceiveSettingsStore(
        Directory(p.join(tmp.path, 'settings')),
      ),
    );

    test(
      'first run with initialMode Off stays Off; turning on is stored',
      () async {
        final e = engine(
          'first',
          receiveConfig: ReceiveConfig(
            store: store,
            initialMode: const ReceiveOff(),
          ),
        );
        expect(await e.start(), 0);
        expect(e.receive.state, const Off(OffReason.neverEnabled));

        await e.receive.turnOn(const ReceiveFor(Duration(hours: 1)));
        final saved = await store.load();
        expect(saved.runtime.state, ReceiveRuntimeState.on);
        expect(saved.runtime.mode, const ReceiveFor(Duration(hours: 1)));
        expect(saved.runtime.until, isNotNull);
        expect(saved.runtime.cleanStop, isFalse);
      },
    );

    test('a store without a record falls back to the initial mode', () async {
      final e = engine('fresh', receiveConfig: ReceiveConfig(store: store));
      expect(await e.start(), greaterThan(0));
    });

    test('a clean stop does not restart receiving on the next start', () async {
      final first = engine(
        'clean1',
        receiveConfig: ReceiveConfig(store: store),
      );
      expect(await first.start(), greaterThan(0));
      await first.dispose();
      expect((await store.load()).runtime.cleanStop, isTrue);

      final second = engine(
        'clean2',
        receiveConfig: ReceiveConfig(store: store),
      );
      expect(await second.start(), 0);
      expect(second.receive.state, const Off(OffReason.user));
    });

    test('a crash inside the window restores On with the time left', () async {
      await store.save(
        ReceivePersisted(
          runtime: ReceiveRuntime(
            state: ReceiveRuntimeState.on,
            mode: const ReceiveFor(Duration(hours: 1)),
            until: DateTime.now().toUtc().add(const Duration(minutes: 30)),
            cleanStop: false,
          ),
        ),
      );
      final e = engine(
        'crash',
        receiveConfig: ReceiveConfig(
          store: store,
          initialMode: const ReceiveOff(),
        ),
      );
      final port = await e.start();
      expect(port, greaterThan(0));
      final on = e.receive.state as On;
      expect(
        on.until!.difference(DateTime.now()).inMinutes,
        inInclusiveRange(28, 30),
      );
      expect(await infoStatus(port), 200);
    });

    test('a user stop hint overrides a crash record', () async {
      await store.save(
        const ReceivePersisted(
          runtime: ReceiveRuntime(
            state: ReceiveRuntimeState.on,
            mode: ReceiveAlways(),
            cleanStop: false,
          ),
        ),
      );
      final e = engine(
        'hint',
        receiveConfig: ReceiveConfig(
          store: store,
          exitHint: ExitHint.userStopped,
        ),
      );
      expect(await e.start(), 0);
      expect(e.receive.state, const Off(OffReason.user));
    });
  });

  test('start() rethrows the bind error when no port is free, and the engine stays usable', () async {
    PortBlocker blocker;
    try {
      blocker = PortBlocker.bind(kPortFallbackMax);
    } on SocketException {
      markTestSkipped('port $kPortFallbackMax is in use on this host');
      return;
    }
    addTearDown(blocker.close);

    final e = engine('nofree', preferredPort: kPortFallbackMax);
    await expectLater(e.start(), throwsA(isA<SocketException>()));
    expect(e.isStarted, isTrue);
    expect(e.receive.state, isA<Failed>());
    expect(e.isRunning, isFalse);

    await blocker.close();
    await e.receive.turnOn(const ReceiveAlways());
    expect(e.receive.state, isA<On>());
    expect(e.port, kPortFallbackMax);
  });

  test('contacts-only visibility is refused until pairing exists', () async {
    final e = engine('contacts');
    await e.start();
    await expectLater(
      e.receive.setVisibility(ReceiveVisibility.contacts),
      throwsUnsupportedError,
    );
    expect((e.receive.state as On).visibility, ReceiveVisibility.everyone);
    expect(await infoStatus(e.port), 200);
  });

  test(
    'stop() mid-window leaves the controller reusable for the next start',
    () async {
      final e = engine(
        'restart',
        receiveConfig: const ReceiveConfig(
          initialMode: ReceiveFor(Duration(hours: 1)),
        ),
      );
      final first = await e.start();
      await e.stop();
      expect(e.receive.state, const Off(OffReason.user));
      expect(await infoStatus(first), isNull);
      final second = await e.start();
      expect(await infoStatus(second), 200);
      expect((e.receive.state as On).until, isNotNull);
    },
  );
}
