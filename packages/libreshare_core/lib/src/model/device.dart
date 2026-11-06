library;

import '../protocol.dart';

class DeviceAddress {
  const DeviceAddress(this.ip, {this.iface = 'unknown'});
  final String ip;
  final String iface; // wifi | ethernet | unknown
  Map<String, Object?> toJson() => {'ip': ip, 'if': iface};
  factory DeviceAddress.fromJson(Map<String, Object?> j) => DeviceAddress(
    j['ip']! as String,
    iface: (j['if'] as String?) ?? 'unknown',
  );
}

/// DeviceInfo as returned by GET /info and carried in SessionRequest.sender.
class DeviceInfo {
  const DeviceInfo({
    required this.deviceId,
    required this.alias,
    required this.platform,
    this.deviceType = 'desktop',
    this.fingerprint = '',
    this.port = kDefaultPort,
    this.addrs = const [],
    this.caps = const ['resume'],
    this.version = kProtocolVersion,
  });

  final String deviceId;
  final String alias;
  final String platform;
  final String deviceType;
  final String
  fingerprint; // uppercase hex SHA-256 of DER cert; '' before TLS (Inc 3)
  final int port;
  final List<DeviceAddress> addrs;
  final List<String> caps;
  final String version;

  Map<String, Object?> toJson() => {
    'proto': kProtocolName,
    'v': version,
    'deviceId': deviceId,
    'alias': alias,
    'platform': platform,
    'deviceType': deviceType,
    'fingerprint': fingerprint,
    'port': port,
    'addrs': addrs.map((a) => a.toJson()).toList(),
    'caps': caps,
  };

  factory DeviceInfo.fromJson(Map<String, Object?> j) => DeviceInfo(
    deviceId: j['deviceId']! as String,
    alias: j['alias']! as String,
    platform: (j['platform'] as String?) ?? 'unknown',
    deviceType: (j['deviceType'] as String?) ?? 'desktop',
    fingerprint: (j['fingerprint'] as String?) ?? '',
    port: (j['port'] as int?) ?? kDefaultPort,
    addrs: ((j['addrs'] as List?) ?? const [])
        .map((e) => DeviceAddress.fromJson((e as Map).cast<String, Object?>()))
        .toList(),
    caps: ((j['caps'] as List?) ?? const []).cast<String>(),
    version: (j['v'] as String?) ?? kProtocolVersion,
  );
}
