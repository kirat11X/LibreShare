// Inc 4 acceptance helpers: plaintext engine nodes on loopback, candidates,
// a shared scenario runner and a receiver that can really be SIGKILLed
// (inc4_receiver_main.dart in a child process).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_data.dart';

const int mib = 1024 * 1024;

/// One in-process engine with its download dir and every event it emitted
/// (with the wall-clock time it was received).
class IncNode {
  IncNode(this.name, this.engine, this.rx);

  final String name;
  final LibreShareEngine engine;
  final Directory rx;
  late int port;
  final List<LsEvent> events = [];
  final List<DateTime> eventTimes = [];
  late final StreamSubscription<LsEvent> _sub;

  List<T> of<T extends LsEvent>() => events.whereType<T>().toList();

  List<ChannelEvent> get channelEvents => [
    for (final e in events)
      if (e is ChannelStateChanged) e.event,
  ];

  /// First time a [ChannelTierSwitched] reached the engine's event stream.
  DateTime? get firstSwitchAt {
    for (var i = 0; i < events.length; i++) {
      final e = events[i];
      if (e is ChannelStateChanged && e.event is ChannelTierSwitched) {
        return eventTimes[i];
      }
    }
    return null;
  }

  Future<void> dispose() async {
    await _sub.cancel();
    await engine.dispose(force: true);
  }
}

Future<IncNode> startNode(
  Directory sandbox,
  String name, {
  String ip = '127.0.0.1',
  int preferredPort = 0,
  Directory? rx,
  Clock clock = const SystemClock(),
  bool autoAccept = true,
}) async {
  final dir = rx ?? Directory(p.join(sandbox.path, 'rx-$name'));
  final engine = LibreShareEngine(
    self: DeviceInfo(
      deviceId: 'device-$name',
      alias: 'Engine-$name',
      platform: 'linux',
    ),
    downloadDir: dir,
    preferredPort: preferredPort,
    autoAccept: autoAccept,
    bindAddress: InternetAddress(ip),
    enableRateLimit: false,
    clock: clock,
  );
  final node = IncNode(name, engine, dir);
  node._sub = engine.events.listen((e) {
    node.events.add(e);
    node.eventTimes.add(DateTime.now());
  });
  node.port = await engine.start();
  return node;
}

DiscoveredDevice deviceFor(
  IncNode n, {
  String address = '127.0.0.1',
  List<String> addrs = const ['127.0.0.1'],
}) => DiscoveredDevice(
  info: DeviceInfo(
    deviceId: n.engine.self.deviceId,
    alias: n.engine.self.alias,
    platform: 'linux',
    port: n.port,
    addrs: [for (final a in addrs) DeviceAddress(a)],
  ),
  address: address,
  lastSeen: DateTime.now(),
  source: DiscoverySource.multicast,
);

Candidate candidate(
  CandidateKind kind,
  int port, {
  String host = '127.0.0.1',
}) => Candidate.create(kind: kind, host: host, port: port, peerFingerprint: '');

Future<void> untilTrue(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 20),
  String what = 'condition',
  Duration step = const Duration(milliseconds: 5),
}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) fail('$what not met within $timeout');
    await Future<void>.delayed(step);
  }
}

File source(Directory sandbox, String name, int size, {int seed = 1}) =>
    writeRandomFile(
      Directory(p.join(sandbox.path, 'src')),
      name,
      size,
      seed: seed,
    );

/// `.lspart` / `.lspart.json` files below [dir].
List<String> lsparts(Directory dir) => partialLeftovers(dir);

/// Where the packages/libreshare_core directory is (tests run with it as cwd).
String get coreDir {
  var d = Directory.current;
  for (var i = 0; i < 4; i++) {
    if (File(p.join(d.path, 'test', 'helpers', 'inc4_receiver_main.dart'))
        .existsSync()) {
      return d.path;
    }
    d = d.parent;
  }
  return Directory.current.path;
}

/// A receiver in a child process that can be killed with SIGKILL, so no
/// shutdown hook, flush or dispose runs (a real crash).
class CrashableReceiver {
  CrashableReceiver._(this.process, this.port, this.dir);

  final Process process;
  final int port;
  final Directory dir;
  final List<String> stderrLines = [];

  /// [clockOffset] shifts the child's clock (24 h sidecar window tests).
  static Future<CrashableReceiver> start({
    required Directory dir,
    Duration clockOffset = Duration.zero,
    int port = 0,
  }) async {
    final proc = await Process.start(Platform.resolvedExecutable, [
      p.join('test', 'helpers', 'inc4_receiver_main.dart'),
      '--dir',
      dir.path,
      '--port',
      '$port',
      '--clock-offset-seconds',
      '${clockOffset.inSeconds}',
    ], workingDirectory: coreDir);
    final ready = Completer<int>();
    final lines = <String>[];
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
      l,
    ) {
      if (l.startsWith('READY ') && !ready.isCompleted) {
        ready.complete(int.parse(l.substring(6)));
      }
    });
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add);
    final bound = await ready.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        throw StateError('receiver child did not become ready: $lines');
      },
    );
    return CrashableReceiver._(proc, bound, dir).._copy(lines);
  }

  void _copy(List<String> l) => stderrLines.addAll(l);

  /// SIGKILL and wait until the process is gone.
  Future<void> kill9() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 10));
  }
}
