// Shared fixtures for the P6b (secure discovery) tests: real P-256 identities,
// hand-built bye datagrams (independent of the production codec), and small
// discovery nodes on the in-memory multicast bus.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:test/test.dart';

/// A device with a real identity (key + self-signed certificate).
class P6bPeer {
  P6bPeer(String deviceId)
    : key = KeyIdentity.fromGenerated(generateIdentityFor(deviceId));

  final KeyIdentity key;

  String get id => key.identity.deviceId;
  String get fp => key.identity.fingerprint;
  Uint8List get certDer => key.identity.certDer;

  /// What this device announces about itself in the secure profile.
  DeviceInfo info({
    int port = kDefaultPort,
    String? fingerprint,
    String version = kProtocolVersionSecure,
    List<DeviceAddress> addrs = const [],
  }) => DeviceInfo(
    deviceId: id,
    alias: 'dev-$id',
    platform: 'linux',
    fingerprint: fingerprint ?? fp,
    port: port,
    addrs: addrs,
    caps: const ['resume', 'sas', 'pair'],
    version: version,
  );
}

int tsOf(DateTime t) => t.toUtc().millisecondsSinceEpoch;

/// The text LSP-1 4.2 rule 9 signs: deviceId + fingerprint + ts, no separators.
List<int> byeText(String deviceId, String fingerprint, int ts) =>
    utf8.encode('$deviceId$fingerprint$ts');

/// A bye datagram assembled by hand from the spec (NOT through `encodeBye`).
/// Defaults describe a correct bye of [from]; every field can be overridden to
/// build a forged one. [signer] defaults to [from]; [domain] to `LSP1-BYE`.
Uint8List rawBye(
  P6bPeer from, {
  required int ts,
  String? deviceId,
  String? fingerprint,
  P6bPeer? signer,
  String domain = SigDomain.bye,
  Uint8List? sig,
  String version = '1.1',
  Map<String, Object?> extra = const {},
}) {
  final id = deviceId ?? from.id;
  final fp = fingerprint ?? from.fp;
  final signature =
      sig ?? (signer ?? from).key.sign(domain, byeText(id, fp, ts));
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'proto': 'libreshare',
        'v': version,
        't': 'bye',
        'deviceId': id,
        'fingerprint': fp,
        'ts': ts,
        'sig': b64urlEncode(signature),
        ...extra,
      }),
    ),
  );
}

Future<void> settle() => pumpEventQueue(times: 50);

Future<void> eventually(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 3),
  String what = 'condition',
}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('$what not met in $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// One discovery instance (transport + registry + trust store + discovery) on
/// a shared in-memory bus. Timers are parked far in the future unless asked
/// for, so a test drives announcements explicitly.
class P6bNode {
  P6bNode(
    this.bus,
    this.peer, {
    this.secure = true,
    Clock? clock,
    PeerRegistrar? registrar,
    bool Function()? contactsOnly,
    bool probes = false,
    int apiPort = kDefaultPort,
    List<Duration> schedule = const [],
    Duration periodic = const Duration(hours: 1),
    String? address,
  }) : trust = InMemoryTrustStore(),
       transport = bus.createTransport(address: address) {
    final c = clock ?? const SystemClock();
    registry = PeerRegistry(
      selfDeviceId: peer.id,
      clock: c,
      trust: secure ? trust : null,
    );
    info = secure
        ? peer.info(port: apiPort)
        : DeviceInfo(
            deviceId: peer.id,
            alias: 'dev-${peer.id}',
            platform: 'linux',
            port: apiPort,
          );
    discovery = MulticastDiscovery(
      selfInfo: () => info,
      transport: transport,
      registry: registry,
      registrar: registrar,
      clock: c,
      announceSchedule: schedule,
      periodicInterval: periodic,
      interfacePoll: const Duration(hours: 1),
      probes: probes,
      security: secure
          ? SecurityConfig.tls(identity: peer.key, trust: trust)
          : const SecurityConfig.plaintext(),
      contactsOnly: contactsOnly,
    );
  }

  final InMemoryMulticastBus bus;
  final P6bPeer peer;
  final bool secure;
  final InMemoryTrustStore trust;
  final InMemoryMulticastTransport transport;
  late final PeerRegistry registry;
  late final MulticastDiscovery discovery;
  late DeviceInfo info;

  /// Lists [other] as a peer heard by multicast (without any datagram).
  void listPeer(
    P6bPeer other, {
    String address = '10.0.0.200',
    DiscoverySource source = DiscoverySource.multicast,
    int port = kDefaultPort,
  }) => registry.seen(other.info(port: port), address, source);

  /// Delivers raw bytes to this node as if [from] had multicast them.
  void hear(List<int> bytes, {String from = '10.0.0.77'}) =>
      transport.inject(bytes, from: from);

  List<String> get listed => [for (final d in registry.current) d.id]..sort();

  Future<void> dispose() async {
    await discovery.stop();
    registry.dispose();
  }
}

/// A bare bus participant: records what it receives and can send raw bytes.
class P6bBare {
  P6bBare(InMemoryMulticastBus bus, {String address = '10.0.0.50'})
    : transport = bus.createTransport(address: address) {
    transport.packets.listen(received.add);
  }

  final InMemoryMulticastTransport transport;
  final List<MulticastPacket> received = [];

  Future<void> start() => transport.start();

  void multicast(List<int> bytes) => transport.sendMulticast(bytes);

  void announce(DeviceInfo info, {bool announce = true, bool probe = false}) =>
      transport.sendMulticast(
        encodeAnnounce(info, announce: announce, probe: probe),
      );

  /// Announce datagrams received (probes allowed).
  List<AnnounceMessage> get announces => [
    for (final p in received) ?decodeAnnounce(p.data, allowProbe: true),
  ];
}
