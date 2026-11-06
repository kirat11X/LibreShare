/// mDNS behind an interface (spec §1: `bonsoir` implements it in the app layer).
library;

class MdnsService {
  const MdnsService({
    required this.name,
    required this.port,
    this.txt = const {},
  });
  final String name; // instance name
  final int port;
  final Map<String, String> txt; // id, fp (16 hex), v, pf
}

class MdnsPeer {
  const MdnsPeer({
    required this.name,
    required this.addresses,
    required this.port,
    this.txt = const {},
  });
  final String name;
  final List<String> addresses; // IPv4/IPv6 literals
  final int port;
  final Map<String, String> txt;
}

abstract interface class MdnsBackend {
  /// Advertise `_libreshare._tcp`.
  Future<void> advertise(MdnsService service);
  Future<void> stopAdvertising();

  /// Browse `_libreshare._tcp`; emits each resolved peer (repeatedly is fine).
  Stream<MdnsPeer> browse();
  Future<void> stopBrowsing();
}
