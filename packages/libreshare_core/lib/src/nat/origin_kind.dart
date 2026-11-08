// Origin kind definitions for Increment 5b direct & tunnel candidates.

/// Represents the transport and origin category for link and direct connection candidates.
enum OriginKind {
  directIpv6('ipv6', priority: 10),
  mappedIpv4('mapped4', priority: 20),
  tunnelCloudflare('cf', priority: 30),
  tunnelZrok('zrok', priority: 40),
  manual('manual', priority: 50);

  const OriginKind(this.wireName, {required this.priority});

  final String wireName;
  final int priority;

  static OriginKind? fromWireName(String name) {
    for (final kind in values) {
      if (kind.wireName == name) return kind;
    }
    return null;
  }

  @override
  String toString() => wireName;
}
