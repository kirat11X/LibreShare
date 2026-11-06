// Test rig: the real app (providers, router, screens) on top of a REAL
// LibreShareEngine whose discovery runs over the core's in-memory multicast
// bus, with other real engines ("peers") on loopback aliases 127.0.0.N. Only
// the OS adapters are fakes (PlatformServices.fake()).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/app.dart';
import 'package:libreshare_app/platform/platform_services.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/providers/platform_providers.dart';
import 'package:libreshare_app/providers/router_provider.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_app/services/app_dirs.dart';
import 'package:libreshare_app/services/app_settings_store.dart';
import 'package:libreshare_app/services/file_launcher.dart';
import 'package:libreshare_app/services/file_picker_service.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:uuid/uuid.dart';

/// One clock for both roles: wall time ([Clock]) and Receive-mode timers
/// ([ReceiveScheduler]). Time only moves when the test calls [advance], which
/// also fires due timers (a window ending, a warning) in order.
class ManualClock implements Clock, ReceiveScheduler {
  ManualClock([DateTime? start]) : _now = start ?? DateTime(2026, 11, 3, 12);

  DateTime _now;
  Duration _mono = Duration.zero;
  final List<_ManualTimer> _timers = [];

  @override
  DateTime now() => _now;

  @override
  Timer once(Duration delay, void Function() callback) {
    final t = _ManualTimer(this, _mono + delay, callback);
    _timers.add(t);
    return t;
  }

  /// Moves time forward by [d] and fires every timer that falls due.
  void advance(Duration d) {
    final target = _mono + d;
    while (true) {
      final due = _timers.where((t) => t.active && t.at <= target).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final t = due.first;
      _now = _now.add(t.at - _mono);
      _mono = t.at;
      t.fire();
    }
    _now = _now.add(target - _mono);
    _mono = target;
  }
}

class _ManualTimer implements Timer {
  _ManualTimer(this._clock, this.at, this._callback);

  final ManualClock _clock;
  final Duration at;
  final void Function() _callback;
  bool active = true;

  void fire() {
    if (!active) return;
    active = false;
    _callback();
  }

  @override
  void cancel() {
    active = false;
    _clock._timers.remove(this);
  }

  @override
  bool get isActive => active;

  @override
  int get tick => 0;
}

class FakeIfaces implements NetworkInterfaceProvider {
  FakeIfaces([this.items = const []]);

  List<LocalInterface> items;

  @override
  Future<List<LocalInterface>> list() async => List.of(items);
}

/// Another device: a real engine on its own loopback alias.
class TestPeer {
  TestPeer(
    this.name,
    this.ip,
    this.engine,
    this.rx,
    this.events, [
    this.wiring,
  ]);

  final String name;
  final String ip;
  final LibreShareEngine engine;
  final Directory rx;
  final List<LsEvent> events;

  /// Set when this device runs the secure profile (TLS, own identity).
  final SecurityWiring? wiring;

  String get id => engine.self.deviceId;

  /// Sends [files] to the app under test (which must be receiving).
  Future<SendResult> sendTo(AppHarness h, List<File> files) async {
    final w = wiring;
    if (w != null) {
      // A secure sender that already knows the app (a contact) does not ask
      // for the verification code: the same flow as the plaintext fixture.
      await w.trust.pin(
        deviceId: h.engine.self.deviceId,
        fingerprint: h.engine.ownFingerprint,
        alias: h.engine.self.alias,
        trust: PeerTrust.known,
      );
    }
    return engine.sendFiles(
      files,
      host: '127.0.0.2',
      port: h.engine.port,
      chunkConcurrency: 2,
    );
  }

  /// The first incoming session this peer's receiver saw (as a receiver).
  String? get incomingSessionId => events
      .whereType<SessionCreated>()
      .where((e) => !e.outgoing)
      .map((e) => e.sessionId)
      .firstOrNull;
}

class AppHarness {
  AppHarness._(this.sandbox, this.services) {
    picker = FakeFilePickerService();
    launcher = FakeFileLauncher();
  }

  final Directory sandbox;
  final PlatformServices services;
  final InMemoryMulticastBus bus = InMemoryMulticastBus();
  final ManualClock clock = ManualClock();
  late final FakeFilePickerService picker;
  late final FakeFileLauncher launcher;
  late ProviderContainer container;
  final List<TestPeer> peers = [];
  int _nextHost = 3;

  /// Peers started from now on run the secure profile (the app's own engine
  /// always does, so a plaintext device cannot send to it).
  static bool securePeers = false;

  /// The app's engine is secure, but these tests use plaintext fixture peers
  /// (engines without `security:`): lets the app's engine talk to them (the
  /// engine's own opt-in for legacy devices, and a plain `/info` probe for
  /// manual entry and links). Off by default, so the secure tests keep the
  /// real secure behaviour.
  static bool legacyPlaintextPeers = false;

  late Directory supportDir;
  late Directory defaultDownloads;

  /// The app's own engine (null until it started).
  LibreShareEngine get engine => container.read(engineOrNullProvider)!;

  /// Creates the sandbox and the container; the engine is started by [boot].
  /// Call inside `tester.runAsync`.
  static Future<AppHarness> create({
    PlatformServices? services,
    String alias = 'Test-Laptop',
    Duration permissionTimeout = const Duration(seconds: 120),
    ReceiveMode initialMode = const ReceiveOff(),
    String? initialLocation,
    ReceiveScheduler? scheduler,
    Directory? reuseSandbox,
    int preferredPort = 0,
    bool qrScanSupported = false,
    List<Override> overrides = const [],
  }) async {
    // flutter_test answers every HttpClient request with a canned 400; the
    // engines under test talk real HTTP over loopback.
    HttpOverrides.global = null;
    final sandbox =
        reuseSandbox ?? Directory.systemTemp.createTempSync('ls_app_test_');
    final h = AppHarness._(sandbox, services ?? PlatformServices.fake());
    h.supportDir = Directory('${sandbox.path}/support')
      ..createSync(recursive: true);
    h.defaultDownloads = Directory('${sandbox.path}/Downloads/LibreShare');
    final store = AppSettingsStore(h.supportDir);
    final settings = await store.loadOrCreate(defaultAlias: alias);
    final saved = settings.preferredPort == preferredPort
        ? settings
        : settings.copyWith(preferredPort: preferredPort);
    h.container = ProviderContainer(
      retry: (count, error) => null,
      overrides: [
        platformServicesProvider.overrideWithValue(h.services),
        clockProvider.overrideWithValue(h.clock),
        appDirsProvider.overrideWithValue(
          AppDirs(
            supportDir: h.supportDir,
            defaultDownloadDir: h.defaultDownloads,
          ),
        ),
        initialAppSettingsProvider.overrideWithValue(saved),
        filePickerServiceProvider.overrideWithValue(h.picker),
        fileLauncherProvider.overrideWithValue(h.launcher),
        // Desktop-like by default (flutter_test reports Android).
        qrScanSupportedProvider.overrideWithValue(qrScanSupported),
        ...overrides,
        if (initialLocation != null)
          initialLocationProvider.overrideWithValue(initialLocation),
        engineTuningProvider.overrideWithValue(
          EngineTuning(
            bindAddress: InternetAddress('127.0.0.2'),
            enableRateLimit: false,
            permissionTimeout: permissionTimeout,
            initialMode: initialMode,
            allowInsecurePeers: legacyPlaintextPeers,
            scheduler: scheduler ?? h.clock,
            discovery: DiscoveryConfig(
              multicastTransport: () =>
                  h.bus.createTransport(address: '127.0.0.2'),
              interfaces: FakeIfaces(),
              autoScan: false,
              infoProbe: legacyPlaintextPeers ? defaultInfoProbe : null,
              announceSchedule: const [],
              announceInterval: const Duration(hours: 1),
              interfacePoll: const Duration(hours: 1),
            ),
          ),
        ),
      ],
    );
    return h;
  }

  /// Starts the app's engine. Call inside `tester.runAsync`.
  Future<void> boot() async {
    await container.read(engineProvider.future);
  }

  /// Another real device that is receiving (or not).
  Future<TestPeer> startPeer(
    String name, {
    bool autoAccept = true,
    ReceiveMode mode = const ReceiveAlways(),
    String platform = 'android',
    Duration permissionTimeout = const Duration(seconds: 120),
    bool discover = true,
    bool? secure,
  }) async {
    final ip = '127.0.0.${_nextHost++}';
    final rx = Directory('${sandbox.path}/rx-$name');
    final wiring = (secure ?? securePeers)
        ? await SecurityWiring.open(
            directory: Directory('${sandbox.path}/sec-$name'),
            deviceId: const Uuid().v4(),
          )
        : null;
    final engine = LibreShareEngine(
      self: DeviceInfo(
        deviceId: wiring?.identity.identity.deviceId ?? const Uuid().v4(),
        alias: name,
        platform: platform,
        deviceType: platform == 'android' ? 'mobile' : 'desktop',
      ),
      downloadDir: rx,
      preferredPort: 0,
      autoAccept: autoAccept,
      bindAddress: InternetAddress(ip),
      enableRateLimit: false,
      permissionTimeout: permissionTimeout,
      discovery: discover
          ? DiscoveryConfig(
              multicastTransport: () => bus.createTransport(address: ip),
              interfaces: FakeIfaces(),
              autoScan: false,
              announceSchedule: const [],
              announceInterval: const Duration(hours: 1),
              interfacePoll: const Duration(hours: 1),
            )
          : DiscoveryConfig.disabled,
      receiveConfig: ReceiveConfig(initialMode: mode),
      security: wiring,
    );
    final events = <LsEvent>[];
    engine.events.listen(events.add);
    final peer = TestPeer(name, ip, engine, rx, events, wiring);
    peers.add(peer);
    await engine.start();
    return peer;
  }

  /// The app as a widget (a fresh `MaterialApp.router`).
  Widget get app => UncontrolledProviderScope(
    container: container,
    child: const LibreShareApp(),
  );

  /// Creates a file of [bytes] bytes with a recognisable pattern.
  File makeFile(String name, int bytes) {
    final f = File('${sandbox.path}/src/$name')..createSync(recursive: true);
    f.writeAsBytesSync(List<int>.generate(bytes, (i) => (i * 31 + 7) & 0xff));
    return f;
  }

  PickedFile pick(File f) => PickedFile.fromFile(f);

  /// Stops everything. Call inside `tester.runAsync`.
  Future<void> dispose({bool deleteSandbox = true}) async {
    // Dispose the container first: it cancels every listener the widgets put
    // on the engine's streams (they live in the fake-async zone, whose
    // microtasks cannot run while we wait here) and then closes the engine.
    final notifier = container.read(engineProvider.notifier);
    container.dispose();
    await notifier.closed;
    for (final p in peers) {
      await p.engine.dispose(force: true);
      await p.wiring?.close();
    }
    peers.clear();
    if (!deleteSandbox) return;
    try {
      sandbox.deleteSync(recursive: true);
    } on Object {
      // best effort
    }
  }
}

extension HarnessTester on WidgetTester {
  /// A tall window so long lists (Settings) are fully built.
  void useTallSurface({double width = 900, double height = 2600}) {
    view.physicalSize = Size(width, height);
    view.devicePixelRatio = 1;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  }

  /// Lets real I/O (sockets, files) run for [ms] and then flushes the fake
  /// async queue with a frame.
  Future<void> settle({int ms = 25, int rounds = 1}) async {
    for (var i = 0; i < rounds; i++) {
      await runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
      // Fake time follows real time, so timers the UI started (timeouts,
      // periodic ticks) behave as they would on a device.
      await pump(Duration(milliseconds: ms));
    }
  }

  /// Settles until [cond] holds (checked after each round); fails after
  /// [maxRounds] x [ms].
  Future<void> settleUntil(
    bool Function() cond, {
    int ms = 20,
    int maxRounds = 300,
    String what = 'condition',
  }) async {
    for (var i = 0; i < maxRounds; i++) {
      if (cond()) break;
      await settle(ms: ms);
    }
    if (!cond()) {
      final texts = [
        for (final e in find.byType(Text).evaluate())
          if ((e.widget as Text).data != null) (e.widget as Text).data!,
      ];
      fail(
        '$what not met after ${maxRounds * ms} ms of real time; '
        'visible texts: $texts',
      );
    }
    // Let providers and widgets react to what just happened.
    await pump();
    await pump();
  }

  /// Boots the app on [h] and shows the first frame.
  Future<void> startApp(AppHarness h) async {
    await runAsync(h.boot);
    await pumpWidget(h.app);
    await settle();
    await pump();
  }

  /// Ends the test cleanly: unmounts the tree, then stops engines.
  Future<void> stopApp(AppHarness h, {bool deleteSandbox = true}) async {
    await pumpWidget(const SizedBox.shrink());
    // Work the UI started (file writes, socket closes) finishes in real time
    // but its continuations run in the fake-async zone, so the engine's own
    // shutdown can queue behind them. Start the shutdown in the real zone and
    // keep flushing the fake zone until it is through.
    var done = false;
    await runAsync(() async {
      unawaited(
        h.dispose(deleteSandbox: deleteSandbox).whenComplete(() => done = true),
      );
    });
    for (var i = 0; i < 500 && !done; i++) {
      await runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await pump();
    }
    expect(done, isTrue, reason: 'the engines shut down');
    // Timeouts the UI's own work armed (a sender's 120 s wait for consent)
    // must not outlive the test.
    await pump(const Duration(minutes: 3));
  }
}

/// Replaces the system clipboard with [text] for the length of the test.
void mockClipboard(WidgetTester tester, {String? text, List<String>? written}) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.getData') {
        return text == null ? null : <String, Object?>{'text': text};
      }
      if (call.method == 'Clipboard.setData') {
        written?.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}
