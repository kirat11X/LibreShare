/// In-memory [MulticastTransport] test double: any number of transports share
/// one [InMemoryMulticastBus], which delivers multicast to every started
/// transport (including the sender, like real multicast loopback) and unicast
/// to the transport whose address and port match. Delivery is asynchronous
/// (microtask), as on a real socket. Not for production use.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../protocol.dart';
import '../multicast_transport.dart';

/// One send attempt recorded by the bus.
class SentDatagram {
  const SentDatagram({
    required this.from,
    required this.data,
    required this.multicast,
    required this.dropped,
    this.to,
    this.toPort,
  });

  final InMemoryMulticastTransport from;
  final Uint8List data;

  /// True for [MulticastTransport.sendMulticast], false for unicast.
  final bool multicast;
  final InternetAddress? to;
  final int? toPort;

  /// The bus discarded it (blackhole, blocked kind, or simulated loss).
  final bool dropped;
}

class InMemoryMulticastBus {
  InMemoryMulticastBus({this.lossRate = 0, int seed = 7})
    : _random = Random(seed);

  /// Probability (0..1) that any single delivery is silently lost.
  double lossRate;

  /// Drop everything (a network that swallows all traffic).
  bool blackhole = false;

  /// Drop only multicast (e.g. IGMP snooping / blocked UDP 53318) ...
  bool dropMulticast = false;

  /// ... or only unicast.
  bool dropUnicast = false;

  /// Every send attempt in order, including dropped ones.
  final List<SentDatagram> sent = [];

  final Random _random;
  final List<InMemoryMulticastTransport> _members = [];
  int _nextHost = 2;

  /// Creates a transport on this bus. [address] defaults to a unique
  /// `10.0.0.N`; [port] is the UDP port it listens on and sends from.
  InMemoryMulticastTransport createTransport({
    String? address,
    int port = kDefaultPort,
    bool loopback = true,
  }) => InMemoryMulticastTransport._(
    this,
    InternetAddress(address ?? '10.0.0.${_nextHost++}'),
    port,
    loopback,
  );

  /// Unicast datagrams only.
  List<SentDatagram> get unicasts => [
    for (final s in sent)
      if (!s.multicast) s,
  ];

  /// Multicast datagrams only.
  List<SentDatagram> get multicasts => [
    for (final s in sent)
      if (s.multicast) s,
  ];

  bool _lose(bool multicast) {
    if (blackhole) return true;
    if (multicast ? dropMulticast : dropUnicast) return true;
    // Random loss: per receiver for multicast (see _multicast), per datagram
    // for unicast.
    return !multicast && lossRate > 0 && _random.nextDouble() < lossRate;
  }

  void _multicast(InMemoryMulticastTransport from, List<int> data) {
    final bytes = Uint8List.fromList(data);
    final dropped = _lose(true);
    sent.add(
      SentDatagram(from: from, data: bytes, multicast: true, dropped: dropped),
    );
    if (dropped) return;
    for (final m in List.of(_members)) {
      if (m.port != from.port) continue;
      if (identical(m, from) && !from.loopback) continue;
      // Per-receiver loss, so one packet can reach some peers only.
      if (!identical(m, from) &&
          lossRate > 0 &&
          _random.nextDouble() < lossRate) {
        continue;
      }
      m._deliver(bytes, from);
    }
  }

  void _unicast(
    InMemoryMulticastTransport from,
    List<int> data,
    InternetAddress to,
    int toPort,
  ) {
    final bytes = Uint8List.fromList(data);
    final dropped = _lose(false);
    sent.add(
      SentDatagram(
        from: from,
        data: bytes,
        multicast: false,
        dropped: dropped,
        to: to,
        toPort: toPort,
      ),
    );
    if (dropped) return;
    for (final m in List.of(_members)) {
      if (m.address == to && m.port == toPort) m._deliver(bytes, from);
    }
  }
}

class InMemoryMulticastTransport implements MulticastTransport {
  InMemoryMulticastTransport._(
    this._bus,
    this.address,
    this.port,
    this.loopback,
  );

  final InMemoryMulticastBus _bus;

  /// Source address stamped on this transport's datagrams and the address
  /// unicast replies must target. Assignable (e.g. to simulate a second
  /// interface or several hosts behind one IP).
  InternetAddress address;

  /// UDP port this transport listens on and sends from.
  final int port;
  final bool loopback;

  final StreamController<MulticastPacket> _packets =
      StreamController<MulticastPacket>.broadcast();
  bool _started = false;

  /// How often [rejoin] was called.
  int rejoinCount = 0;

  bool get isStarted => _started;

  @override
  Stream<MulticastPacket> get packets => _packets.stream;

  /// Convenience: assigns [address] from a literal.
  void setAddress(String ip) => address = InternetAddress(ip);

  /// Delivers a hand-made packet to this transport's listeners, bypassing the
  /// bus (no loss, not recorded). For hostile-input tests.
  void inject(
    List<int> data, {
    required String from,
    int fromPort = kDefaultPort,
  }) {
    if (!_started) return;
    final bytes = Uint8List.fromList(data);
    scheduleMicrotask(() {
      if (_started) {
        _packets.add(
          MulticastPacket(
            data: bytes,
            source: InternetAddress(from),
            port: fromPort,
          ),
        );
      }
    });
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _bus._members.add(this);
  }

  @override
  Future<void> stop() async {
    _started = false;
    _bus._members.remove(this);
  }

  @override
  Future<void> rejoin() async {
    rejoinCount++;
  }

  @override
  void sendMulticast(List<int> data) {
    if (!_started) return;
    _bus._multicast(this, data);
  }

  @override
  void sendUnicast(List<int> data, InternetAddress address, int port) {
    if (!_started) return;
    _bus._unicast(this, data, address, port);
  }

  void _deliver(Uint8List bytes, InMemoryMulticastTransport from) {
    final packet = MulticastPacket(
      data: bytes,
      source: from.address,
      port: from.port,
    );
    scheduleMicrotask(() {
      if (_started) _packets.add(packet);
    });
  }
}
