/// UDP multicast transport behind an interface (spec §4.2), so discovery logic
/// is testable without sockets. [RawMulticastTransport] is the dart:io
/// implementation; `testing/in_memory_multicast.dart` has the test double.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../protocol.dart';
import 'network_interfaces.dart';

/// One received datagram. [source]/[port] are the sender's UDP endpoint; for
/// LibreShare peers [port] is also the port their multicast listener is bound
/// to, i.e. where a unicast reply must go.
class MulticastPacket {
  const MulticastPacket({
    required this.data,
    required this.source,
    required this.port,
  });
  final List<int> data;
  final InternetAddress source;
  final int port;
}

abstract interface class MulticastTransport {
  /// Opens the socket and joins the group. Throws if the port cannot be bound.
  Future<void> start();

  /// Received datagrams (broadcast; valid across start/stop).
  Stream<MulticastPacket> get packets;

  /// Sends [data] to the multicast group (best effort, on every interface).
  void sendMulticast(List<int> data);

  /// Sends [data] to one peer (best effort).
  void sendUnicast(List<int> data, InternetAddress address, int port);

  /// Re-joins the group on the current interface set (after a network change).
  Future<void> rejoin();

  /// Closes the socket. Idempotent; [start] may be called again.
  Future<void> stop();
}

/// Optional capability of a [MulticastTransport]: send a send-only probe (LSP-1
/// 4.2 rule 8) from a socket with its OWN ephemeral source port, which also
/// receives the unicast replies. Needed on a host that runs several LibreShare
/// processes: they share the discovery port (`SO_REUSEPORT`), so a reply sent
/// to "probe source:port" = the shared port is delivered to one of the sockets
/// bound to it (often the replier's own), not necessarily to the prober.
abstract interface class ProbeFromEphemeralPort {
  /// Multicasts [data] from the ephemeral probe socket (opened on first use,
  /// closed by `stop`). Best effort.
  void sendProbeFromEphemeralPort(List<int> data);
}

/// [MulticastTransport] over a `RawDatagramSocket` bound to `0.0.0.0:port`.
///
/// * The group is joined on every non-loopback IPv4 interface reported by
///   [ifaces]; if none can be joined it falls back to the OS default join.
/// * Multicast is sent once per interface (`IP_MULTICAST_IF`), so peers on
///   every attached network hear us; if that fails it falls back to a plain
///   send. Per-interface failures are logged and tolerated.
/// * Datagrams are sent from the listening socket, so a receiver can answer
///   [MulticastPacket.port] directly.
class RawMulticastTransport
    implements MulticastTransport, ProbeFromEphemeralPort {
  RawMulticastTransport({
    this.ifaces = const SystemNetworkInterfaceProvider(),
    this.port = kDefaultPort,
    this.group = kMulticastGroup,
    this.loopback = true,
  });

  final NetworkInterfaceProvider ifaces;

  /// UDP port to bind and send to. Tests use a non-default port.
  final int port;
  final String group;

  /// Whether the OS loops our own multicast back to local sockets (needed for
  /// two instances on one host; the discovery layer filters its own packets).
  final bool loopback;

  static final Logger _log = Logger('libreshare.discovery.multicast');

  final StreamController<MulticastPacket> _packets =
      StreamController<MulticastPacket>.broadcast();

  RawDatagramSocket? _socket;
  RawDatagramSocket? _probeSocket;
  Future<RawDatagramSocket?>? _probeOpening;
  StreamSubscription<RawSocketEvent>? _probeSub;
  StreamSubscription<RawSocketEvent>? _sub;
  late InternetAddress _group;
  List<LocalInterface> _sendIfaces = const [];
  final List<NetworkInterface?> _joined = [];
  Future<void>? _starting;

  @override
  Stream<MulticastPacket> get packets => _packets.stream;

  /// Local UDP port in use (differs from [port] only if [port] was 0).
  int? get boundPort => _socket?.port;

  @override
  Future<void> start() => _starting ??= _start().whenComplete(() {
    _starting = null;
  });

  Future<void> _start() async {
    if (_socket != null) return;
    _group = InternetAddress(group);
    final socket = await _bind();
    try {
      socket.multicastLoopback = loopback;
      socket.multicastHops = 1;
    } on Object catch (e) {
      _log.fine('could not tune multicast socket options: $e');
    }
    _socket = socket;
    _sub = socket.listen(
      (event) {
        if (event == RawSocketEvent.read) _drain(socket);
      },
      onError: (Object e) => _log.fine('socket error: $e'),
      cancelOnError: false,
    );
    await _join(socket);
  }

  // Read events are edge-triggered: drain until empty, but yield to the event
  // loop every 64 datagrams so a flood cannot starve the isolate.
  void _drain(RawDatagramSocket socket) {
    if (!identical(socket, _socket) && !identical(socket, _probeSocket)) return;
    for (var i = 0; i < 64; i++) {
      final d = socket.receive();
      if (d == null) return;
      _packets.add(
        MulticastPacket(data: d.data, source: d.address, port: d.port),
      );
    }
    Timer.run(() => _drain(socket));
  }

  Future<RawDatagramSocket> _bind() async {
    try {
      return await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
    } on Object catch (e) {
      // reusePort is unsupported on some platforms; reuseAddress alone is
      // enough there.
      _log.fine('bind with reusePort failed ($e); retrying without');
      return RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
    }
  }

  Future<List<LocalInterface>> _listIfaces() async {
    try {
      return (await ifaces.list())
          .where(
            (i) => !i.address.isLoopback && i.address.rawAddress.length == 4,
          )
          .toList();
    } on Object catch (e) {
      _log.warning('listing network interfaces failed: $e');
      return const [];
    }
  }

  Future<void> _join(RawDatagramSocket socket) async {
    final local = await _listIfaces();
    _sendIfaces = local;

    // NetworkInterface objects (needed by joinMulticast) matched by name; a
    // provider that reports names the OS does not know falls back to default.
    var system = const <NetworkInterface>[];
    try {
      system = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
    } on Object catch (e) {
      _log.fine('NetworkInterface.list failed: $e');
    }
    final byName = {for (final n in system) n.name: n};

    var joined = 0;
    final done = <String>{};
    for (final li in local) {
      if (!done.add(li.name)) continue; // one membership per interface
      final ni = byName[li.name];
      if (ni == null) continue;
      try {
        socket.joinMulticast(_group, ni);
        _joined.add(ni);
        joined++;
      } on Object catch (e) {
        _log.fine('join $group on ${li.name} failed: $e');
      }
    }
    if (joined == 0) {
      try {
        socket.joinMulticast(_group);
        _joined.add(null);
        joined++;
      } on Object catch (e) {
        _log.warning('joining $group failed on every interface: $e');
      }
    }
    _log.fine('joined $group:$port on $joined interface(s)');
  }

  @override
  Future<void> rejoin() async {
    final socket = _socket;
    if (socket == null) return;
    for (final ni in _joined) {
      try {
        socket.leaveMulticast(_group, ni);
      } on Object catch (e) {
        _log.fine('leave failed: $e');
      }
    }
    _joined.clear();
    await _join(socket);
  }

  @override
  void sendMulticast(List<int> data) {
    final socket = _socket;
    if (socket == null) return;
    _sendGroup(socket, data);
  }

  void _sendGroup(RawDatagramSocket socket, List<int> data) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    var sent = false;
    for (final li in _sendIfaces) {
      try {
        socket.setRawOption(
          RawSocketOption(
            RawSocketOption.levelIPv4,
            RawSocketOption.IPv4MulticastInterface,
            li.address.rawAddress,
          ),
        );
        if (socket.send(bytes, _group, port) > 0) sent = true;
      } on Object catch (e) {
        _log.fine('multicast send via ${li.name} failed: $e');
      }
    }
    if (!sent) {
      try {
        socket.send(bytes, _group, port);
      } on Object catch (e) {
        _log.warning('multicast send failed: $e');
      }
    }
  }

  @override
  void sendProbeFromEphemeralPort(List<int> data) {
    if (_socket == null) return;
    final open = _probeSocket;
    if (open != null) {
      _sendGroup(open, data);
      return;
    }
    // Opened on first use; this probe goes out as soon as the socket exists.
    final opening = _probeOpening ??= _openProbeSocket();
    opening.then((s) {
      if (s != null) _sendGroup(s, data);
    });
  }

  Future<RawDatagramSocket?> _openProbeSocket() async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      if (_socket == null) {
        s.close();
        return null;
      }
      try {
        s.multicastLoopback = loopback;
        s.multicastHops = 1;
      } on Object catch (e) {
        _log.fine('could not tune probe socket options: $e');
      }
      _probeSocket = s;
      _probeSub = s.listen(
        (event) {
          if (event == RawSocketEvent.read) _drain(s);
        },
        onError: (Object e) => _log.fine('probe socket error: $e'),
        cancelOnError: false,
      );
      return s;
    } on Object catch (e) {
      _log.fine('probe socket unavailable: $e');
      return null;
    } finally {
      _probeOpening = null;
    }
  }

  @override
  void sendUnicast(List<int> data, InternetAddress address, int port) {
    try {
      _socket?.send(data, address, port);
    } on Object catch (e) {
      _log.fine('unicast send failed: $e');
    }
  }

  @override
  Future<void> stop() async {
    await _starting?.catchError((Object _) {});
    final socket = _socket;
    _socket = null;
    await _sub?.cancel();
    _sub = null;
    _joined.clear();
    _sendIfaces = const [];
    final probe = _probeSocket;
    _probeSocket = null;
    await _probeSub?.cancel();
    _probeSub = null;
    probe?.close();
    socket?.close();
  }
}
