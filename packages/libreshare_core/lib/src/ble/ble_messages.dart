import 'dart:convert';

/// A candidate address reported over BLE for fast local LAN fallback.
class LanCandidate {
  const LanCandidate({required this.ip, required this.port, this.iface});

  final String ip;
  final int port;
  final String? iface;

  Map<String, Object?> toJson() => {
    'ip': ip,
    'port': port,
    if (iface != null) 'iface': iface,
  };

  factory LanCandidate.fromJson(Map<String, Object?> json) => LanCandidate(
    ip: json['ip']! as String,
    port: json['port']! as int,
    iface: json['iface'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LanCandidate &&
          ip == other.ip &&
          port == other.port &&
          iface == other.iface;

  @override
  int get hashCode => Object.hash(ip, port, iface);
}

/// Sealed hierarchy of messages exchanged over GATT during LS-BLE/1 handoff.
sealed class BleMessage {
  const BleMessage();

  String get type;

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());

  static BleMessage fromJson(Map<String, Object?> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'm1':
        return BleM1.fromJson(json);
      case 'm2':
        return BleM2.fromJson(json);
      case 'auth':
        return BleAuth.fromJson(json);
      case 'offer':
        return BleOffer.fromJson(json);
      case 'decision':
        return BleDecision.fromJson(json);
      case 'net_plan':
        return BleNetPlan.fromJson(json);
      case 'hotspot':
        return BleHotspot.fromJson(json);
      case 'joined':
        return BleJoined.fromJson(json);
      default:
        throw FormatException('Unknown BleMessage type: $type');
    }
  }

  static BleMessage decode(String text) =>
      fromJson(jsonDecode(text) as Map<String, Object?>);
}

/// M1 Hello message from Central to Peripheral.
final class BleM1 extends BleMessage {
  const BleM1({this.v = 1, required this.epk, required this.n, this.eidHint});

  final int v;
  final String epk;
  final String n;
  final String? eidHint;

  @override
  String get type => 'm1';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'v': v,
    'epk': epk,
    'n': n,
    if (eidHint != null) 'eidHint': eidHint,
  };

  factory BleM1.fromJson(Map<String, Object?> json) => BleM1(
    v: (json['v'] as int?) ?? 1,
    epk: json['epk']! as String,
    n: json['n']! as String,
    eidHint: json['eidHint'] as String?,
  );
}

/// M2 Hello message from Peripheral to Central.
final class BleM2 extends BleMessage {
  const BleM2({
    this.v = 1,
    required this.epk,
    required this.n,
    required this.capEcho,
  });

  final int v;
  final String epk;
  final String n;
  final int capEcho;

  @override
  String get type => 'm2';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'v': v,
    'epk': epk,
    'n': n,
    'capEcho': capEcho,
  };

  factory BleM2.fromJson(Map<String, Object?> json) => BleM2(
    v: (json['v'] as int?) ?? 1,
    epk: json['epk']! as String,
    n: json['n']! as String,
    capEcho: json['capEcho']! as int,
  );
}

/// Authenticated handshake identity and local candidates.
final class BleAuth extends BleMessage {
  const BleAuth({
    required this.certDerB64,
    required this.sigB64,
    required this.alias,
    required this.platform,
    this.lanCands = const [],
  });

  final String certDerB64;
  final String sigB64;
  final String alias;
  final String platform;
  final List<LanCandidate> lanCands;

  @override
  String get type => 'auth';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'certDerB64': certDerB64,
    'sigB64': sigB64,
    'alias': alias,
    'platform': platform,
    'lanCands': [for (final c in lanCands) c.toJson()],
  };

  factory BleAuth.fromJson(Map<String, Object?> json) => BleAuth(
    certDerB64: json['certDerB64']! as String,
    sigB64: json['sigB64']! as String,
    alias: json['alias']! as String,
    platform: json['platform']! as String,
    lanCands: [
      if (json['lanCands'] != null)
        for (final c in json['lanCands']! as List)
          LanCandidate.fromJson(c as Map<String, Object?>),
    ],
  );
}

/// File transfer offer initiated over GATT.
final class BleOffer extends BleMessage {
  const BleOffer({
    required this.offerId,
    required this.fileCount,
    required this.totalSize,
    required this.firstName,
    this.lanCands = const [],
    this.hostPref = 0,
  });

  final String offerId;
  final int fileCount;
  final int totalSize;
  final String firstName;
  final List<LanCandidate> lanCands;
  final int hostPref;

  @override
  String get type => 'offer';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'offerId': offerId,
    'fileCount': fileCount,
    'totalSize': totalSize,
    'firstName': firstName,
    'lanCands': [for (final c in lanCands) c.toJson()],
    'hostPref': hostPref,
  };

  factory BleOffer.fromJson(Map<String, Object?> json) => BleOffer(
    offerId: json['offerId']! as String,
    fileCount: json['fileCount']! as int,
    totalSize: json['totalSize']! as int,
    firstName: json['firstName']! as String,
    lanCands: [
      if (json['lanCands'] != null)
        for (final c in json['lanCands']! as List)
          LanCandidate.fromJson(c as Map<String, Object?>),
    ],
    hostPref: (json['hostPref'] as int?) ?? 0,
  );
}

/// Receiver consent decision (accept/reject) for an offer.
final class BleDecision extends BleMessage {
  const BleDecision({required this.offerId, required this.accept, this.reason});

  final String offerId;
  final bool accept;
  final String? reason;

  @override
  String get type => 'decision';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'offerId': offerId,
    'accept': accept,
    if (reason != null) 'reason': reason,
  };

  factory BleDecision.fromJson(Map<String, Object?> json) => BleDecision(
    offerId: json['offerId']! as String,
    accept: json['accept']! as bool,
    reason: json['reason'] as String?,
  );
}

/// Agreed network execution plan.
final class BleNetPlan extends BleMessage {
  const BleNetPlan({
    required this.offerId,
    required this.hostRole,
    required this.pathKind,
  });

  final String offerId;
  final String hostRole; // 'host' or 'join'
  final String pathKind; // 'lan' or 'hotspot'

  @override
  String get type => 'net_plan';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'offerId': offerId,
    'hostRole': hostRole,
    'pathKind': pathKind,
  };

  factory BleNetPlan.fromJson(Map<String, Object?> json) => BleNetPlan(
    offerId: json['offerId']! as String,
    hostRole: json['hostRole']! as String,
    pathKind: json['pathKind']! as String,
  );
}

/// Hotspot credentials and connection parameters.
final class BleHotspot extends BleMessage {
  const BleHotspot({
    required this.offerId,
    required this.ssid,
    required this.psk,
    this.band = 0,
    required this.hostIp,
    required this.port,
    required this.certFp,
    required this.validUntil,
  });

  final String offerId;
  final String ssid;
  final String psk;
  final int band;
  final String hostIp;
  final int port;
  final String certFp;
  final String validUntil;

  @override
  String get type => 'hotspot';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'offerId': offerId,
    'ssid': ssid,
    'psk': psk,
    'band': band,
    'hostIp': hostIp,
    'port': port,
    'certFp': certFp,
    'validUntil': validUntil,
  };

  factory BleHotspot.fromJson(Map<String, Object?> json) => BleHotspot(
    offerId: json['offerId']! as String,
    ssid: json['ssid']! as String,
    psk: json['psk']! as String,
    band: (json['band'] as int?) ?? 0,
    hostIp: json['hostIp']! as String,
    port: json['port']! as int,
    certFp: json['certFp']! as String,
    validUntil: json['validUntil']! as String,
  );
}

/// Confirmation from joiner that it has joined the hotspot.
final class BleJoined extends BleMessage {
  const BleJoined({required this.offerId, required this.clientIp});

  final String offerId;
  final String clientIp;

  @override
  String get type => 'joined';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'offerId': offerId,
    'clientIp': clientIp,
  };

  factory BleJoined.fromJson(Map<String, Object?> json) => BleJoined(
    offerId: json['offerId']! as String,
    clientIp: json['clientIp']! as String,
  );
}
