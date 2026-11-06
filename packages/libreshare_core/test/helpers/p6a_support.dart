// Shared builders for the P6a (engine facade) tests: secure and plaintext engines on loopback
// aliases, optionally with discovery over the in-memory bus, an event recorder, and the user who
// presses Accept after the SAS code was shown.
//
// New symbols this file needs (not in the tree yet; the tests fail to compile on them):
//   SecurityWiring.open(...)                      lib/src/engine/security_wiring.dart
//   LibreShareEngine(..., security:, advertiseIp:) and the new engine members used below.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'discovery_rig.dart' show FakeIfaces, loopbackAliasesWork;
import 'test_data.dart';

export 'discovery_rig.dart' show FakeIfaces, loopbackAliasesWork;
export 'test_data.dart';

const String loopback = '127.0.0.1';

/// Skip reason when 127.0.0.2.. cannot be bound (macOS without aliases), else null.
Future<String?> p6aSkipReason() async => await loopbackAliasesWork()
    ? null
    : '127.0.0.2 cannot be bound on this host';

String newDeviceId() => const Uuid().v4();

/// Polls [cond] every 10 ms; fails with [what] after [timeout].
Future<void> until(
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

/// Lets queued events and late packets show up (<= 200 ms, loopback only).
Future<void> settle([int ms = 150]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Records every [LsEvent] of a stream.
class P6aEvents {
  P6aEvents(Stream<LsEvent> events) {
    _sub = events.listen(all.add);
  }

  final List<LsEvent> all = [];
  late final StreamSubscription<LsEvent> _sub;

  List<T> of<T extends LsEvent>() => all.whereType<T>().toList();

  /// The first event of type [T] matching [test] (events that already happened count).
  Future<T> next<T extends LsEvent>({
    bool Function(T e)? test,
    Duration timeout = const Duration(seconds: 8),
    String? what,
  }) async {
    T? found;
    await until(
      () {
        for (final e in all.whereType<T>()) {
          if (test == null || test(e)) {
            found = e;
            return true;
          }
        }
        return false;
      },
      timeout: timeout,
      what: what ?? 'event $T',
    );
    return found!;
  }

  Future<void> close() => _sub.cancel();
}

/// One engine plus everything a test needs to inspect it.
class P6aNode {
  P6aNode._({
    required this.name,
    required this.deviceId,
    required this.ip,
    required this.idDir,
    required this.rx,
    required this.wiring,
    required this.engine,
    required this.events,
    required this.acceptSas,
  });

  final String name;
  final String deviceId;
  final String ip;
  final Directory idDir;
  final Directory rx;
  final SecurityWiring? wiring;
  final LibreShareEngine engine;
  final P6aEvents events;

  /// The user presses Accept as soon as the SAS code is shown (true), or does nothing (false).
  bool acceptSas;

  bool get isSecure => wiring != null;
  int get port => engine.port;

  /// Own fingerprint (64 uppercase hex) of a secure node.
  String get fp => wiring!.identity.identity.fingerprint;

  /// SAS codes shown on this node, by direction.
  List<String> sasCodes({required bool outgoing}) => [
    for (final e in events.of<SasReady>())
      if (e.outgoing == outgoing) e.code,
  ];

  Future<void> dispose() async {
    await engine.dispose(force: true);
    await events.close();
    await wiring?.close();
  }
}

class P6aRig {
  P6aRig(this.sandbox);

  final Directory sandbox;
  final InMemoryMulticastBus bus = InMemoryMulticastBus();
  final List<P6aNode> nodes = [];
  int _next = 2;

  /// Counts every start ever made: unlike `nodes.length` it never shrinks after [stop], so a restarted
  /// device never reuses (and inherits the files of) its predecessor's download directory.
  int _started = 0;

  /// Opens (or re-opens, with the same [idDir]) the wiring. Separate so a test can restart a device.
  Future<SecurityWiring> openWiring({
    required Directory idDir,
    required String deviceId,
    PinPolicy pinPolicy = const PinPolicy.off(),
    String? pin,
    ConsentPolicy consent = const ConsentPolicy(),
    bool allowInsecurePeers = false,
  }) => SecurityWiring.open(
    directory: idDir,
    deviceId: deviceId,
    pinPolicy: pinPolicy,
    pin: pin,
    consent: consent,
    allowInsecurePeers: allowInsecurePeers,
  );

  Future<P6aNode> start(
    String name, {
    bool secure = true,
    String? deviceId,
    Directory? idDir,
    bool autoAccept = true,
    bool acceptSas = true,
    PinPolicy pinPolicy = const PinPolicy.off(),
    String? pin,
    ConsentPolicy consent = const ConsentPolicy(),
    bool allowInsecurePeers = false,
    bool discovery = false,
    ReceiveMode mode = const ReceiveAlways(),
    Duration permissionTimeout = kPermissionTimeout,
    Duration peerExpiry = const Duration(seconds: 90),
    Duration announceInterval = const Duration(milliseconds: 300),
    String? advertiseIp,
    String? ip,
    String platform = 'linux',
  }) async {
    final address = ip ?? '127.0.0.${_next++}';
    final seq = _started++;
    final dir = idDir ?? Directory(p.join(sandbox.path, 'id-$name-$seq'));
    final id = deviceId ?? newDeviceId();
    final wiring = secure
        ? await openWiring(
            idDir: dir,
            deviceId: id,
            pinPolicy: pinPolicy,
            pin: pin,
            consent: consent,
            allowInsecurePeers: allowInsecurePeers,
          )
        : null;
    final effectiveId = wiring?.identity.identity.deviceId ?? id;
    final rx = Directory(p.join(sandbox.path, 'rx-$name-$seq'));
    final engine = LibreShareEngine(
      self: DeviceInfo(deviceId: effectiveId, alias: name, platform: platform),
      downloadDir: rx,
      preferredPort: 0,
      autoAccept: autoAccept,
      bindAddress: InternetAddress(address),
      enableRateLimit: false,
      permissionTimeout: permissionTimeout,
      security: wiring,
      advertiseIp: advertiseIp,
      discovery: discovery
          ? DiscoveryConfig(
              multicastTransport: () => bus.createTransport(address: address),
              interfaces: FakeIfaces(),
              autoScan: false,
              announceSchedule: const [],
              announceInterval: announceInterval,
              interfacePoll: const Duration(hours: 1),
              peerExpiry: peerExpiry,
            )
          : DiscoveryConfig.disabled,
      receiveConfig: ReceiveConfig(initialMode: mode),
    );
    final events = P6aEvents(engine.events);
    final node = P6aNode._(
      name: name,
      deviceId: effectiveId,
      ip: address,
      idDir: dir,
      rx: rx,
      wiring: wiring,
      engine: engine,
      events: events,
      acceptSas: acceptSas,
    );
    // The user at the receiver compares the codes and presses Accept.
    engine.events.listen((e) {
      if (e is SasReady && !e.outgoing && node.acceptSas) {
        unawaited(
          engine.receiver.accept(e.sessionId).then((_) {}, onError: (_) {}),
        );
      }
    });
    nodes.add(node);
    await engine.start();
    return node;
  }

  /// Stops [node]'s engine (its identity directory stays) so a test can start it again.
  Future<void> stop(P6aNode node) async {
    await node.engine.dispose(force: true);
    await node.events.close();
    await node.wiring?.close();
    nodes.remove(node);
  }

  Future<void> dispose() async {
    for (final n in nodes.toList()) {
      await n.dispose();
    }
    nodes.clear();
  }
}

/// `from` sends [files] to `to` by address.
Future<SendResult> sendTo(
  P6aNode from,
  P6aNode to,
  List<File> files, {
  String? pin,
  Duration acceptTimeout = kPermissionTimeout,
}) async {
  final res = await from.engine.sendFiles(
    files,
    host: to.ip,
    port: to.port,
    pin: pin,
    acceptTimeout: acceptTimeout,
  );
  await settle(50);
  return res;
}

/// Regular files in [dir] (recursive) whose name contains `.lspart`.
List<String> leftovers(Directory dir) => partialLeftovers(dir);

/// Asserts [dst] is a byte-identical copy of [src].
Future<void> expectSameFile(File src, File dst) async {
  expect(dst.existsSync(), isTrue, reason: '${dst.path} missing');
  expect(dst.lengthSync(), src.lengthSync(), reason: 'length of ${dst.path}');
  expect(await sha256OfFileHex(dst), await sha256OfFileHex(src));
  expect(await filesIdentical(src, dst), isTrue, reason: dst.path);
}

/// Base64url text of the key material in [pem] (the PEM body), for sentinel searches.
String pemBody(Uint8List pem) => utf8
    .decode(pem)
    .split('\n')
    .where((l) => l.isNotEmpty && !l.startsWith('-----'))
    .join();

/// The contacts of [node] by device id.
Map<String, Contact> contactsOf(P6aNode node) => {
  for (final c in node.engine.currentContacts) c.deviceId: c,
};

/// GET [path] over TLS without verifying the certificate (the test inspects the bytes), or over
/// plain HTTP when [tls] is false. Returns status and body; never follows redirects.
Future<({int status, String body, Map<String, String> headers})> rawGet(
  String host,
  int port,
  String path, {
  bool tls = true,
  Map<String, String> headers = const {},
}) async {
  final c = HttpClient();
  c.badCertificateCallback = (_, _, _) => true;
  c.findProxy = (_) => 'DIRECT';
  try {
    final req = await c.getUrl(
      Uri.parse('${tls ? 'https' : 'http'}://$host:$port$path'),
    );
    req.followRedirects = false;
    headers.forEach(req.headers.set);
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    final h = <String, String>{};
    res.headers.forEach((k, v) => h[k] = v.join(','));
    return (status: res.statusCode, body: body, headers: h);
  } finally {
    c.close(force: true);
  }
}

/// A transparent TCP relay in front of [targetPort] that keeps a copy of every byte in both
/// directions: what an eavesdropper on the wire would see.
class TcpTap {
  TcpTap._(this._server, this.host, this.targetPort) {
    _server.listen(_onClient);
  }

  static Future<TcpTap> start(String host, int targetPort) async => TcpTap._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    host,
    targetPort,
  );

  final ServerSocket _server;
  final String host;
  final int targetPort;
  final BytesBuilder _seen = BytesBuilder(copy: true);
  final List<Socket> _sockets = [];

  int get port => _server.port;

  /// Everything that crossed the relay, both directions, in arrival order.
  List<int> get captured => _seen.toBytes();

  bool sawBytes(List<int> needle) {
    final data = _seen.toBytes();
    if (needle.isEmpty) return true;
    outer:
    for (var i = 0; i + needle.length <= data.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (data[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  Future<void> _onClient(Socket client) async {
    final Socket upstream;
    try {
      upstream = await Socket.connect(host, targetPort);
    } on Object {
      client.destroy();
      return;
    }
    _sockets
      ..add(client)
      ..add(upstream);
    void pipe(Socket from, Socket to) {
      from.listen(
        (d) {
          _seen.add(d);
          try {
            to.add(d);
          } on Object {
            // peer already gone
          }
        },
        onDone: () => to.destroy(),
        onError: (_) => to.destroy(),
        cancelOnError: true,
      );
    }

    pipe(client, upstream);
    pipe(upstream, client);
  }

  Future<void> close() async {
    await _server.close();
    for (final s in _sockets) {
      s.destroy();
    }
  }
}
