// Shared helpers of the D1 round-2 tests (d1_probe_*, d1b_*): seeding a support
// directory, a real secure receiver ("Bob"), failure injection for the PIN
// slot, log capture and a few UI waits. Nothing here asserts a D1 behaviour:
// the assertions live in the test files and go through keys and visible texts.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/services/app_settings_store.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:logging/logging.dart';

import 'harness.dart';

/// A hang must cost a minute, not the 10-minute testWidgets default.
const Timeout kSixtySeconds = Timeout(Duration(seconds: 60));

// Exact user-visible strings fixed by docs/plans/d1-fixes.md.
const String kCouldNotSave = 'Could not save the PIN. Nothing was changed.';
const String kPinNeedsReset =
    'Your saved PIN could not be read. A temporary PIN is shown on the '
    'Receive card until you set a new one.';
const String kWrongPin = 'That PIN was not accepted.';
const String kBlockedText =
    'This device is not accepting PINs right now. Try again later.';

/// The 6-digit PIN used by tests that need "some stored PIN".
const String kSeedPin = '482916';

/// Waits (real time + fake frames) until [cond] holds or the rounds are used
/// up. Never fails by itself: the caller asserts with a meaningful reason.
Future<void> waitFor(
  WidgetTester tester,
  bool Function() cond, {
  int ms = 20,
  int maxRounds = 250,
}) async {
  for (var i = 0; i < maxRounds && !cond(); i++) {
    await tester.settle(ms: ms);
  }
  await tester.pump();
  await tester.pump();
}

/// Same for plain `test`s (real async, no fake clock).
Future<void> waitForReal(
  bool Function() cond, {
  int ms = 20,
  int maxRounds = 250,
}) async {
  for (var i = 0; i < maxRounds && !cond(); i++) {
    await Future<void>.delayed(Duration(milliseconds: ms));
  }
}

bool shown(Finder f) => f.evaluate().isNotEmpty;

LibreShareEngine? engineOf(AppHarness h) =>
    h.container.read(engineOrNullProvider);

PinMode? engineModeOf(AppHarness h) => engineOf(h)?.pinGuard?.policy.mode;

/// Waits for the engine behind `engineProvider` to run with pin mode [m].
Future<void> waitForMode(WidgetTester tester, AppHarness h, PinMode m) =>
    waitFor(tester, () => engineModeOf(h) == m);

/// Boots the engine inside `runAsync` and shows the app. A failing build is a
/// test failure with the exception TYPE only (never its text).
Future<void> bootApp(WidgetTester tester, AppHarness h) async {
  Object? error;
  await tester.runAsync(() async {
    try {
      await h.boot();
    } on Object catch (e) {
      error = e;
    }
  });
  if (error != null) {
    fail('the engine did not build: ${error.runtimeType}');
  }
  await tester.pumpWidget(h.app);
  await tester.settle();
  await tester.pump();
}

/// Shows the app WITHOUT booting the engine first (start failures are shown by
/// the shell).
Future<void> showAppUnbooted(WidgetTester tester, AppHarness h) async {
  await tester.pumpWidget(h.app);
  await tester.settle();
  await tester.pump();
}

Future<void> pickSegment(WidgetTester tester, String label) async {
  final f = find.text(label);
  await scrollToText(tester, f, 'the "$label" choice');
  await tester.tap(f);
  await tester.pump();
}

/// Scrolls [f] to the middle of the window (the app bar must not cover it).
Future<void> centre(WidgetTester tester, Finder f) async {
  await Scrollable.ensureVisible(tester.element(f), alignment: 0.5);
  await tester.pump();
}

Future<void> typePin(WidgetTester tester, String pin) async {
  await centre(tester, find.byKey(const Key('settings-pin-input')));
  await tester.pump();
  await tester.enterText(find.byKey(const Key('settings-pin-input')), pin);
  await tester.pump();
}

Future<void> tapSave(WidgetTester tester) async {
  await centre(tester, find.byKey(const Key('settings-pin-save')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('settings-pin-save')));
  await tester.pump();
}

Future<void> saveFixed(WidgetTester tester, String pin) async {
  await typePin(tester, pin);
  await tapSave(tester);
}

/// Scrolls the first Scrollable until [f] is on screen; fails with [what]
/// (not with "Bad state: No element") when it never appears.
Future<void> scrollToText(WidgetTester tester, Finder f, String what) async {
  final scrollable = find.byType(Scrollable).first;
  for (final dy in const [150.0, -150.0]) {
    try {
      await tester.scrollUntilVisible(
        f,
        dy,
        scrollable: scrollable,
        maxScrolls: 40,
      );
      await tester.pump();
      return;
    } on Object {
      // not in this direction
    }
  }
  fail('$what was not found on the screen');
}

/// The stored `app-pin` value as text, null when there is none.
Future<String?> storedPin(WidgetTester tester, Directory supportDir) async {
  final bytes = await tester.runAsync<Uint8List?>(
    () =>
        FileSecretStore(Directory(pj(supportDir.path, 'security')))
            .get('app-pin'),
  );
  return bytes == null ? null : String.fromCharCodes(bytes);
}

File appPinFile(Directory supportDir) =>
    FileSecretStore(Directory(pj(supportDir.path, 'security')))
        .fileFor('app-pin');

/// Makes the next `FileSecretStore.put('app-pin', ...)` fail for real: its
/// temporary file slot is a non-empty directory. (chmod on the security
/// directory does NOT work: the store sets the directory back to 0700 itself.)
void blockPinWrite(Directory supportDir) {
  final slot = Directory('${appPinFile(supportDir).path}.tmp')
    ..createSync(recursive: true);
  File(pj(slot.path, 'keep')).writeAsStringSync('x');
}

void unblockPinWrite(Directory supportDir) {
  final slot = Directory('${appPinFile(supportDir).path}.tmp');
  if (slot.existsSync()) slot.deleteSync(recursive: true);
}

/// Creates a sandbox whose support directory already holds the app settings
/// (and optionally the stored PIN and/or an identity) the way a previous run
/// would have left them. Use with `AppHarness.create(reuseSandbox: ...)`.
Future<Directory> seedSandbox({
  PinMode mode = PinMode.off,
  String? pin,
  List<int>? pinBytes,
  String deviceId = 'd1b-seed-device-0001',
  String? identityDeviceId,
}) async {
  final sandbox = Directory.systemTemp.createTempSync('ls_d1b_');
  final support = Directory(pj(sandbox.path, 'support'))
    ..createSync(recursive: true);
  await AppSettingsStore(support)
      .save(AppSettings(deviceId: deviceId, alias: 'D1B-Seed', pinMode: mode));
  final secDir = Directory(pj(support.path, 'security'));
  final bytes = pinBytes ?? (pin?.codeUnits);
  if (bytes != null) {
    await FileSecretStore(secDir).put('app-pin', Uint8List.fromList(bytes));
  }
  if (identityDeviceId != null) {
    final w = await SecurityWiring.open(
      directory: secDir,
      deviceId: identityDeviceId,
    );
    await w.close();
  }
  return sandbox;
}

/// Returns the TCP ports in LISTEN state on [ip] that are owned by THIS
/// process (Linux only; empty elsewhere). Other test processes (flutter test
/// --concurrency=2) bind the same loopback alias, so the machine-wide table
/// must be filtered by socket inode: only inodes that appear as
/// `socket:[inode]` links in /proc/self/fd count.
Set<int> listeningPorts(String ip) {
  final f = File('/proc/net/tcp');
  if (!f.existsSync()) return <int>{};
  final mine = <String>{};
  try {
    for (final e in Directory('/proc/self/fd').listSync(followLinks: false)) {
      try {
        final target = Link(e.path).targetSync();
        final m = RegExp(r'^socket:\[(\d+)\]$').firstMatch(target);
        if (m != null) mine.add(m.group(1)!);
      } on FileSystemException {
        // the descriptor was closed meanwhile (or is the directory handle)
      }
    }
  } on FileSystemException {
    return <int>{};
  }
  final hexIp = ip
      .split('.')
      .map(int.parse)
      .toList()
      .reversed
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
  final out = <int>{};
  for (final line in f.readAsLinesSync().skip(1)) {
    final c = line.trim().split(RegExp(r'\s+'));
    if (c.length < 10 || c[3] != '0A') continue;
    final local = c[1].split(':');
    if (local.length == 2 && local[0] == hexIp && mine.contains(c[9])) {
      out.add(int.parse(local[1], radix: 16));
    }
  }
  return out;
}

final bool kHasProcNet = File('/proc/net/tcp').existsSync();

/// Captures `package:logging` records and `debugPrint` output.
class LogCapture {
  LogCapture() : _oldLevel = Logger.root.level, _oldPrint = debugPrint {
    Logger.root.level = Level.ALL;
    _sub = Logger.root.onRecord.listen(
      (r) => lines.add('${r.loggerName} ${r.message} ${r.error ?? ''}'),
    );
    debugPrint = (m, {wrapWidth}) => lines.add(m ?? '');
  }

  final List<String> lines = [];
  final Level _oldLevel;
  final DebugPrintCallback _oldPrint;
  late final StreamSubscription<LogRecord> _sub;

  bool contains(String needle) => lines.any((l) => l.contains(needle));

  void stop() {
    unawaited(_sub.cancel());
    debugPrint = _oldPrint;
    Logger.root.level = _oldLevel;
  }
}

/// A real secure receiver (own identity, PIN policy) on its own loopback
/// address, the way a second LibreShare app would run. It presses Accept when
/// the verification code is shown and auto-accepts otherwise (known contacts).
class SecureBob {
  SecureBob._(this.ip, this.engine, this.wiring, this.rx, this.events);

  final String ip;
  final LibreShareEngine engine;
  final SecurityWiring wiring;
  final Directory rx;
  final List<LsEvent> events;

  static Future<SecureBob> start(
    Directory parent,
    String ip, {
    PinPolicy policy = const PinPolicy(mode: PinMode.fixed),
    String? pin,
    String alias = 'Bob',
  }) async {
    final root = Directory(pj(parent.path, 'bob-$ip'))
      ..createSync(recursive: true);
    final wiring = await SecurityWiring.open(
      directory: Directory(pj(root.path, 'security')),
      deviceId: 'd1b-bob-${ip.replaceAll('.', '-')}',
      pinPolicy: policy,
      pin: pin,
    );
    final rx = Directory(pj(root.path, 'rx'));
    final engine = LibreShareEngine(
      self: DeviceInfo(
        deviceId: wiring.identity.identity.deviceId,
        alias: alias,
        platform: 'linux',
      ),
      downloadDir: rx,
      bindAddress: InternetAddress(ip),
      preferredPort: 0,
      autoAccept: true,
      enableRateLimit: false,
      security: wiring,
      receiveConfig: const ReceiveConfig(initialMode: ReceiveAlways()),
    );
    final events = <LsEvent>[];
    engine.events.listen((e) {
      events.add(e);
      if (e is SasReady && !e.outgoing) {
        unawaited(
          engine.receiver.accept(e.sessionId).then((_) {}, onError: (_) {}),
        );
      }
    });
    await engine.start();
    return SecureBob._(ip, engine, wiring, rx, events);
  }

  DiscoveredDevice get device => DiscoveredDevice(
    info: engine.deviceInfo,
    address: ip,
    lastSeen: DateTime.now(),
    source: DiscoverySource.manual,
  );

  int get incomingSessions =>
      events.whereType<SessionCreated>().where((e) => !e.outgoing).length;

  List<File> get received => rx.existsSync()
      ? rx
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => !f.path.endsWith('.lspart'))
            .toList()
      : <File>[];

  Future<void> close() async {
    try {
      await engine.dispose(force: true);
    } on Object {
      // already closed
    }
    try {
      await wiring.close();
    } on Object {
      // already closed
    }
  }
}

/// Texts of every visible [Text] widget (for "no digits / no counts" checks).
List<String> visibleTexts() => [
  for (final e in find.byType(Text).evaluate())
    if ((e.widget as Text).data != null) (e.widget as Text).data!,
];

/// Joins path parts (the app package does not depend on `package:path`).
String pj(String a, String b, [String? c, String? d]) =>
    [a, b, ?c, ?d].join(Platform.pathSeparator);

String baseName(String path) => path.split(Platform.pathSeparator).last;
