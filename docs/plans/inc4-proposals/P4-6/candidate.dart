/// Candidate endpoint representation for the LibreShare Connection Ladder (Increment 4).
///
/// Models a concrete network path candidate for establishing a secure peer connection.
/// Candidates are ranked according to cost hints, historical success, and measured RTT.
///
/// Security Invariant: Every candidate carries the pinned [peerFingerprint]. A connection
/// attempt MUST verify that the presented certificate matches this fingerprint before
/// any plaintext data or authenticated request is transmitted.
library;

/// Classification of candidate network paths according to ADR 0002.
enum CandidateKind {
  /// Direct mTLS connection over shared WLAN or local hotspot.
  wifi('wifi', defaultCostHint: 10),

  /// Other local network paths (Ethernet, second NIC, other private subnet).
  lan('lan', defaultCostHint: 20),

  /// User-specified or QR-scanned manual address.
  manual('manual', defaultCostHint: 30),

  /// Local loopback connection (tests, local development).
  loopback('loopback', defaultCostHint: 5),

  /// Encrypted relay tunnel (reserved for Increment 5).
  tunnel('tunnel', defaultCostHint: 100);

  const CandidateKind(this.wire, {required this.defaultCostHint});

  /// Wire format identifier used in JSON serialization and protocol messages.
  final String wire;

  /// Default cost metric (lower is cheaper/preferred).
  final int defaultCostHint;

  /// Whether this path is local network / direct rather than relayed.
  bool get isLocal => this != CandidateKind.tunnel;

  /// Resolves [wire] to a [CandidateKind], throwing [ArgumentError] if unknown.
  static CandidateKind fromWire(String wire) {
    for (final kind in CandidateKind.values) {
      if (kind.wire == wire) return kind;
    }
    throw ArgumentError.value(wire, 'wire', 'Unknown candidate kind');
  }
}

/// A network path candidate for peer communication.
class Candidate implements Comparable<Candidate> {
  const Candidate({
    required this.id,
    required this.kind,
    required this.host,
    required this.port,
    required this.peerFingerprint,
    required this.costHint,
    this.lastSuccess,
    this.rtt,
  }) : assert(port > 0 && port <= 65535, 'port must be between 1 and 65535'),
       assert(host.length > 0, 'host must not be empty');

  /// Helper factory that auto-computes [id] and [costHint] if omitted.
  factory Candidate.create({
    required CandidateKind kind,
    required String host,
    required int port,
    required String peerFingerprint,
    String? id,
    int? costHint,
    DateTime? lastSuccess,
    Duration? rtt,
  }) {
    final candidateId = id ?? '${kind.wire}:$host:$port';
    final candidateCost = costHint ?? kind.defaultCostHint;
    return Candidate(
      id: candidateId,
      kind: kind,
      host: host,
      port: port,
      peerFingerprint: peerFingerprint,
      costHint: candidateCost,
      lastSuccess: lastSuccess,
      rtt: rtt,
    );
  }

  /// Unique identifier for this candidate (e.g. "wifi:192.168.1.15:45454").
  final String id;

  /// Path classification tier.
  final CandidateKind kind;

  /// IP address or hostname.
  final String host;

  /// TCP / TLS listening port (1..65535).
  final int port;

  /// SHA-256 certificate fingerprint (hex string) pinned for this peer.
  ///
  /// Invariant: Any TLS connection via this candidate MUST present a certificate
  /// whose SHA-256 fingerprint matches this value.
  final String peerFingerprint;

  /// Cost metric (lower is preferred/cheaper).
  final int costHint;

  /// Timestamp of the last successful request or probe through this candidate.
  final DateTime? lastSuccess;

  /// Most recently measured round-trip time.
  final Duration? rtt;

  /// Verifies that [presentedFingerprint] matches [peerFingerprint].
  ///
  /// Performs case-insensitive comparison ignoring any optional colon delimiters.
  bool matchesFingerprint(String presentedFingerprint) {
    if (peerFingerprint.isEmpty) return true;
    final cleanPresented = presentedFingerprint
        .replaceAll(':', '')
        .trim()
        .toLowerCase();
    final cleanPinned = peerFingerprint
        .replaceAll(':', '')
        .trim()
        .toLowerCase();
    return cleanPresented.isNotEmpty && cleanPresented == cleanPinned;
  }

  /// Creates a copy of this candidate with updated properties.
  Candidate copyWith({
    String? id,
    CandidateKind? kind,
    String? host,
    int? port,
    String? peerFingerprint,
    int? costHint,
    DateTime? lastSuccess,
    Duration? rtt,
  }) {
    return Candidate(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      host: host ?? this.host,
      port: port ?? this.port,
      peerFingerprint: peerFingerprint ?? this.peerFingerprint,
      costHint: costHint ?? this.costHint,
      lastSuccess: lastSuccess ?? this.lastSuccess,
      rtt: rtt ?? this.rtt,
    );
  }

  /// Serializes this candidate to JSON.
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.wire,
    'host': host,
    'port': port,
    'peerFingerprint': peerFingerprint,
    'costHint': costHint,
    if (lastSuccess != null)
      'lastSuccess': lastSuccess!.toUtc().toIso8601String(),
    if (rtt != null) 'rttMs': rtt!.inMilliseconds,
  };

  /// Deserializes a candidate from JSON.
  factory Candidate.fromJson(Map<String, Object?> json) {
    final kind = CandidateKind.fromWire(json['kind']! as String);
    return Candidate(
      id: json['id']! as String,
      kind: kind,
      host: json['host']! as String,
      port: json['port']! as int,
      peerFingerprint: json['peerFingerprint']! as String,
      costHint: (json['costHint'] as int?) ?? kind.defaultCostHint,
      lastSuccess: json['lastSuccess'] != null
          ? DateTime.parse(json['lastSuccess']! as String)
          : null,
      rtt: json['rttMs'] != null
          ? Duration(milliseconds: json['rttMs']! as int)
          : null,
    );
  }

  /// Compares candidates for connection ladder preference:
  /// 1. Lower [costHint] first.
  /// 2. More recent [lastSuccess] first.
  /// 3. Lower [rtt] first (unmeasured RTT placed after measured).
  /// 4. Lexicographical tie-breaker on [id].
  @override
  int compareTo(Candidate other) {
    final costCmp = costHint.compareTo(other.costHint);
    if (costCmp != 0) return costCmp;

    if (lastSuccess != null && other.lastSuccess != null) {
      final successCmp = other.lastSuccess!.compareTo(lastSuccess!);
      if (successCmp != 0) return successCmp;
    } else if (lastSuccess != null) {
      return -1;
    } else if (other.lastSuccess != null) {
      return 1;
    }

    if (rtt != null && other.rtt != null) {
      final rttCmp = rtt!.compareTo(other.rtt!);
      if (rttCmp != 0) return rttCmp;
    } else if (rtt != null) {
      return -1;
    } else if (other.rtt != null) {
      return 1;
    }

    return id.compareTo(other.id);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Candidate &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          kind == other.kind &&
          host == other.host &&
          port == other.port &&
          peerFingerprint == other.peerFingerprint &&
          costHint == other.costHint &&
          lastSuccess == other.lastSuccess &&
          rtt == other.rtt;

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    host,
    port,
    peerFingerprint,
    costHint,
    lastSuccess,
    rtt,
  );

  @override
  String toString() =>
      'Candidate($id, kind=$kind, host=$host:$port, cost=$costHint, rtt=${rtt?.inMilliseconds}ms)';
}
