// Several LibreShareEngines in one process: discovery over an in-memory
// multicast bus (no UDP 53318, no real LAN), transfers over real HTTP on
// loopback aliases (127.0.0.N, one per engine), so what a peer announces is a
// reachable address.
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

class FakeIfaces implements NetworkInterfaceProvider {
  FakeIfaces([this.items = const []]);
  List<LocalInterface> items;

  @override
  Future<List<LocalInterface>> list() async => List.of(items);
}

/// Whether 127.0.0.2 can be bound (Linux/Windows yes, macOS needs an alias).
Future<bool> loopbackAliasesWork() async {
  try {
    final s = await ServerSocket.bind(InternetAddress('127.0.0.2'), 0);
    await s.close();
    return true;
  } on Object {
    return false;
  }
}

Future<void> untilTrue(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
  String? what,
}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) {
      fail('${what ?? 'condition'} not met in $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class RigNode {
  RigNode(this.name, this.ip, this.engine, this.rx, this.events);

  final String name;

  /// Loopback alias this engine's listener and multicast transport live on.
  final String ip;
  final LibreShareEngine engine;
  final Directory rx;
  final List<LsEvent> events;

  String get id => engine.self.deviceId;

  List<String> get seenNames =>
      [for (final d in engine.currentDevices) d.info.alias]..sort();

  DiscoveredDevice? seen(RigNode other) {
    for (final d in engine.currentDevices) {
      if (d.id == other.id) return d;
    }
    return null;
  }
}

class DiscoveryRig {
  DiscoveryRig(this.sandbox);

  final Directory sandbox;
  final InMemoryMulticastBus bus = InMemoryMulticastBus();
  final List<RigNode> nodes = [];
  int _next = 2;

  /// Starts an engine named [name] on the next loopback alias.
  Future<RigNode> start(
    String name, {
    ReceiveMode mode = const ReceiveAlways(),
    bool autoAccept = true,
    int preferredPort = 0,
    bool autoScan = false,
    Duration autoScanDelay = const Duration(milliseconds: 200),
    int scanPort = kDefaultPort,
    bool allowLoopbackScan = false,
    NetworkInterfaceProvider? interfaces,
    MdnsBackend? mdns,
    MulticastTransport Function()? transport,
    ReceiveConfig? receiveConfig,
    String platform = 'linux',
    bool discovery = true,
  }) async {
    final ip = '127.0.0.${_next++}';
    final rx = Directory(p.join(sandbox.path, 'rx-$name'));
    final engine = LibreShareEngine(
      self: DeviceInfo(
        deviceId: const Uuid().v4(),
        alias: name,
        platform: platform,
      ),
      downloadDir: rx,
      preferredPort: preferredPort,
      autoAccept: autoAccept,
      bindAddress: InternetAddress(ip),
      enableRateLimit: false,
      discovery: discovery
          ? DiscoveryConfig(
              multicastTransport:
                  transport ?? () => bus.createTransport(address: ip),
              interfaces: interfaces ?? FakeIfaces(),
              mdns: mdns,
              autoScan: autoScan,
              autoScanDelay: autoScanDelay,
              scanPort: scanPort,
              allowLoopbackScan: allowLoopbackScan,
              announceSchedule: const [],
              announceInterval: const Duration(hours: 1),
              interfacePoll: const Duration(hours: 1),
            )
          : DiscoveryConfig.disabled,
      receiveConfig: receiveConfig ?? ReceiveConfig(initialMode: mode),
    );
    final events = <LsEvent>[];
    engine.events.listen(events.add);
    final node = RigNode(name, ip, engine, rx, events);
    nodes.add(node);
    await engine.start();
    return node;
  }

  Future<void> dispose() async {
    for (final n in nodes) {
      await n.engine.dispose(force: true);
    }
    nodes.clear();
  }
}
