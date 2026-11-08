// Port mapping model for Increment 5b UPnP/NAT-PMP/PCP.

enum PortMappingProtocol {
  tcp('TCP'),
  udp('UDP');

  const PortMappingProtocol(this.wireValue);
  final String wireValue;
}

final class PortMapping {
  const PortMapping({
    required this.internalPort,
    required this.externalPort,
    required this.externalIp,
    required this.protocol,
    required this.leaseDuration,
    required this.createdAt,
    this.description = 'LibreShare',
  });

  final int internalPort;
  final int externalPort;
  final String externalIp;
  final PortMappingProtocol protocol;
  final Duration leaseDuration;
  final DateTime createdAt;
  final String description;

  DateTime get expiresAt => createdAt.add(leaseDuration);

  bool isExpired([DateTime? now]) {
    final current = now ?? DateTime.now();
    return current.isAfter(expiresAt);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PortMapping &&
          runtimeType == other.runtimeType &&
          internalPort == other.internalPort &&
          externalPort == other.externalPort &&
          externalIp == other.externalIp &&
          protocol == other.protocol;

  @override
  int get hashCode =>
      Object.hash(internalPort, externalPort, externalIp, protocol);

  @override
  String toString() =>
      'PortMapping($protocol $internalPort->$externalIp:$externalPort, expires: $expiresAt)';
}
