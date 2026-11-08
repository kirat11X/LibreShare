// Rendezvous record types and JSON serialization per LSP-R1 Section 4.
library;

/// Sealed base class for all decrypted messages in an LSP-R1 envelope.
sealed class RendezvousRecord {
  const RendezvousRecord({
    required this.seq,
    required this.issuedAt,
    this.v = 1,
  });

  /// Protocol version.
  final int v;

  /// Monotonically increasing sequence number per sender/channel.
  final int seq;

  /// Timestamp in milliseconds since Unix epoch when the record was emitted.
  final int issuedAt;

  /// Discriminator tag.
  String get type;

  /// Converts record to JSON map.
  Map<String, Object?> toJson();

  /// Deserializes a record from a JSON map.
  factory RendezvousRecord.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    final v = json['v'] as int? ?? 1;
    final seq = json['seq'] as int? ?? 0;
    final issuedAt = json['issuedAt'] as int? ?? 0;

    switch (type) {
      case 'presence':
        return PresenceRecord(
          seq: seq,
          issuedAt: issuedAt,
          v: v,
          ttl: json['ttl'] as int? ?? 300,
          candidates:
              (json['candidates'] as List?)
                  ?.cast<Map<String, dynamic>>()
                  .toList() ??
              const [],
          caps: (json['caps'] as List?)?.cast<String>().toList() ?? const [],
        );
      case 'probe':
        return ProbeRecord(
          seq: seq,
          issuedAt: issuedAt,
          v: v,
          nonce: json['nonce'] as String? ?? '',
        );
      case 'offer':
        return OfferRecord(
          seq: seq,
          issuedAt: issuedAt,
          v: v,
          offerId: json['offerId'] as String? ?? '',
          manifest: json['manifest'] as Map<String, dynamic>? ?? const {},
          tunnelOffer: json['tunnelOffer'] as Map<String, dynamic>?,
          candidates:
              (json['candidates'] as List?)
                  ?.cast<Map<String, dynamic>>()
                  .toList() ??
              const [],
        );
      case 'reply':
        return ReplyRecord(
          seq: seq,
          issuedAt: issuedAt,
          v: v,
          offerId: json['offerId'] as String? ?? '',
          decision: json['decision'] as String? ?? 'reject',
          sealedAck: json['sealedAck'] as String? ?? '',
        );
      case 'revoke':
        return RevokeRecord(
          seq: seq,
          issuedAt: issuedAt,
          v: v,
          revokedAt: json['revokedAt'] as int? ?? issuedAt,
        );
      case 'pair-hello':
        return PairHelloRecord(
          seq: seq,
          issuedAt: issuedAt,
          v: v,
          scannerFingerprint: json['scannerFingerprint'] as String? ?? '',
          nonce: json['nonce'] as String? ?? '',
          mac: json['mac'] as String? ?? '',
        );
      case 'pair-accept':
        return PairAcceptRecord(
          seq: seq,
          issuedAt: issuedAt,
          v: v,
          inviterFingerprint: json['inviterFingerprint'] as String? ?? '',
          nonce: json['nonce'] as String? ?? '',
          mac: json['mac'] as String? ?? '',
        );
      default:
        throw FormatException('Unknown rendezvous record type: $type');
    }
  }
}

/// Periodic presence ping signaling availability and network candidates.
final class PresenceRecord extends RendezvousRecord {
  const PresenceRecord({
    required super.seq,
    required super.issuedAt,
    super.v,
    this.ttl = 300,
    this.candidates = const [],
    this.caps = const ['rdv1'],
  });

  final int ttl;
  final List<Map<String, dynamic>> candidates;
  final List<String> caps;

  @override
  String get type => 'presence';

  @override
  Map<String, Object?> toJson() => {
    'v': v,
    'type': type,
    'seq': seq,
    'issuedAt': issuedAt,
    'ttl': ttl,
    'candidates': candidates,
    'caps': caps,
  };
}

/// Latency / round-trip probe.
final class ProbeRecord extends RendezvousRecord {
  const ProbeRecord({
    required super.seq,
    required super.issuedAt,
    super.v,
    required this.nonce,
  });

  final String nonce;

  @override
  String get type => 'probe';

  @override
  Map<String, Object?> toJson() => {
    'v': v,
    'type': type,
    'seq': seq,
    'issuedAt': issuedAt,
    'nonce': nonce,
  };
}

/// Transfer session offer carrying manifest summary and connection paths.
final class OfferRecord extends RendezvousRecord {
  const OfferRecord({
    required super.seq,
    required super.issuedAt,
    super.v,
    required this.offerId,
    required this.manifest,
    this.tunnelOffer,
    this.candidates = const [],
  });

  final String offerId;
  final Map<String, dynamic> manifest;
  final Map<String, dynamic>? tunnelOffer;
  final List<Map<String, dynamic>> candidates;

  @override
  String get type => 'offer';

  @override
  Map<String, Object?> toJson() => {
    'v': v,
    'type': type,
    'offerId': offerId,
    'seq': seq,
    'issuedAt': issuedAt,
    'manifest': manifest,
    if (tunnelOffer != null) 'tunnelOffer': tunnelOffer,
    'candidates': candidates,
  };
}

/// Receiver response to an offer.
final class ReplyRecord extends RendezvousRecord {
  const ReplyRecord({
    required super.seq,
    required super.issuedAt,
    super.v,
    required this.offerId,
    required this.decision,
    required this.sealedAck,
  });

  final String offerId;
  final String decision; // 'accept' or 'reject'
  final String sealedAck;

  bool get isAccepted => decision == 'accept';

  @override
  String get type => 'reply';

  @override
  Map<String, Object?> toJson() => {
    'v': v,
    'type': type,
    'offerId': offerId,
    'seq': seq,
    'issuedAt': issuedAt,
    'decision': decision,
    'sealedAck': sealedAck,
  };
}

/// Mutual pairing revocation notice.
final class RevokeRecord extends RendezvousRecord {
  const RevokeRecord({
    required super.seq,
    required super.issuedAt,
    super.v,
    required this.revokedAt,
  });

  final int revokedAt;

  @override
  String get type => 'revoke';

  @override
  Map<String, Object?> toJson() => {
    'v': v,
    'type': type,
    'seq': seq,
    'issuedAt': issuedAt,
    'revokedAt': revokedAt,
  };
}

/// Initial hello scanner handshake over rendezvous.
final class PairHelloRecord extends RendezvousRecord {
  const PairHelloRecord({
    required super.seq,
    required super.issuedAt,
    super.v,
    required this.scannerFingerprint,
    required this.nonce,
    required this.mac,
  });

  final String scannerFingerprint;
  final String nonce;
  final String mac;

  @override
  String get type => 'pair-hello';

  @override
  Map<String, Object?> toJson() => {
    'v': v,
    'type': type,
    'seq': seq,
    'issuedAt': issuedAt,
    'scannerFingerprint': scannerFingerprint,
    'nonce': nonce,
    'mac': mac,
  };
}

/// Inviter acceptance handshake over rendezvous.
final class PairAcceptRecord extends RendezvousRecord {
  const PairAcceptRecord({
    required super.seq,
    required super.issuedAt,
    super.v,
    required this.inviterFingerprint,
    required this.nonce,
    required this.mac,
  });

  final String inviterFingerprint;
  final String nonce;
  final String mac;

  @override
  String get type => 'pair-accept';

  @override
  Map<String, Object?> toJson() => {
    'v': v,
    'type': type,
    'seq': seq,
    'issuedAt': issuedAt,
    'inviterFingerprint': inviterFingerprint,
    'nonce': nonce,
    'mac': mac,
  };
}
