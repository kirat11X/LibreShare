// ReplayGuard enforcing monotonically increasing sequence numbers and clock skew bounds.
library;

import 'records.dart';

/// Validation failure reasons for rendezvous records.
enum ReplayViolation {
  clockSkewExceeded,
  sequenceNotMonotonic,
  duplicateOfferId,
  duplicateNonce,
}

/// Thrown when an incoming rendezvous record violates replay or freshness rules.
class ReplayException implements Exception {
  const ReplayException(this.violation, [this.message = '']);
  final ReplayViolation violation;
  final String message;

  @override
  String toString() =>
      'ReplayException(${violation.name}${message.isNotEmpty ? ': $message' : ''})';
}

/// Tracks received message sequence numbers, nonces, and offer IDs per channel.
class ReplayGuard {
  ReplayGuard({this.maxSkew = const Duration(seconds: 120)});

  final Duration maxSkew;
  final Map<String, int> _highestSeq = {};
  final Set<String> _seenOfferIds = {};
  final Set<String> _seenNonces = {};

  /// Validates [record] freshness and sequencing for [channelIdHex].
  ///
  /// Throws [ReplayException] if any invariant is violated.
  void validate(
    RendezvousRecord record, {
    required String channelIdHex,
    DateTime? now,
  }) {
    final currentTimeMs = (now ?? DateTime.now())
        .toUtc()
        .millisecondsSinceEpoch;
    final skewMs = (currentTimeMs - record.issuedAt).abs();

    if (skewMs > maxSkew.inMilliseconds) {
      throw ReplayException(
        ReplayViolation.clockSkewExceeded,
        'Clock skew of ${skewMs}ms exceeds max allowed ${maxSkew.inMilliseconds}ms',
      );
    }

    final highest = _highestSeq[channelIdHex];
    if (highest != null && record.seq <= highest) {
      throw ReplayException(
        ReplayViolation.sequenceNotMonotonic,
        'Sequence ${record.seq} is not greater than highest seen $highest',
      );
    }

    if (record is OfferRecord) {
      if (_seenOfferIds.contains(record.offerId)) {
        throw ReplayException(
          ReplayViolation.duplicateOfferId,
          'Duplicate offerId ${record.offerId} already processed',
        );
      }
      _seenOfferIds.add(record.offerId);
    } else if (record is ProbeRecord) {
      if (_seenNonces.contains(record.nonce)) {
        throw ReplayException(
          ReplayViolation.duplicateNonce,
          'Duplicate probe nonce ${record.nonce}',
        );
      }
      _seenNonces.add(record.nonce);
    }

    _highestSeq[channelIdHex] = record.seq;
  }

  /// Clears internal state (for testing or key rotation).
  void reset() {
    _highestSeq.clear();
    _seenOfferIds.clear();
    _seenNonces.clear();
  }
}
