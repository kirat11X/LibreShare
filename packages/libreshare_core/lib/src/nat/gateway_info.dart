// Gateway info model for Increment 5b gateway discovery.

enum GatewayProtocol {
  upnpIgd('UPnP-IGD'),
  natPmp('NAT-PMP'),
  pcp('PCP'),
  manual('Manual');

  const GatewayProtocol(this.displayName);
  final String displayName;
}

final class GatewayInfo {
  const GatewayInfo({
    required this.gatewayIp,
    required this.protocol,
    required this.externalIp,
    this.controlUrl,
    this.serverHeader,
  });

  final String gatewayIp;
  final GatewayProtocol protocol;
  final String externalIp;
  final Uri? controlUrl;
  final String? serverHeader;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GatewayInfo &&
          runtimeType == other.runtimeType &&
          gatewayIp == other.gatewayIp &&
          protocol == other.protocol &&
          externalIp == other.externalIp;

  @override
  int get hashCode => Object.hash(gatewayIp, protocol, externalIp);

  @override
  String toString() =>
      'GatewayInfo(${protocol.displayName} via $gatewayIp, external: $externalIp)';
}
