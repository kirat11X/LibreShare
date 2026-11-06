/// Local security refusals of the secure client profile (LSP-1 0.3, 4.7, 5.1; docs/plans/inc3-seams.md
/// "Exceptions crossing package boundaries"). They are deliberately NOT [SocketException]s or
/// [HandshakeException]s: a refusal to talk to a peer must never be mistaken for "unreachable"
/// or retried in the clear.
///
/// All of them carry fixed text. Fingerprints appear only in their short form (16 hex characters,
/// see `shortFp`); nothing else (addresses, nonces, keys) is ever included.
library;

import '../security/contracts.dart' show shortFp;

/// The peer does not speak the secure profile (plaintext listener, LSP/1.0 peer, empty
/// fingerprint) while TLS is required.
class InsecurePeerException implements Exception {
  const InsecurePeerException();

  @override
  String toString() =>
      'InsecurePeerException: peer does not offer the secure profile';
}

/// The certificate the peer presented is not the one pinned (or first seen) for it.
class PeerFingerprintMismatchException implements Exception {
  const PeerFingerprintMismatchException(
    this.expectedShort,
    this.presentedShort,
  );

  /// First 16 hex characters of the fingerprint we required.
  final String expectedShort;

  /// First 16 hex characters of the fingerprint the peer presented.
  final String presentedShort;

  @override
  String toString() =>
      'PeerFingerprintMismatchException: expected ${shortFp(expectedShort)}..., '
      'presented ${shortFp(presentedShort)}...';
}

/// The first-contact SAS flow ended before the users could compare codes (reveal refused or
/// failed, or the user cancelled while the comparison was outstanding).
class SasAbortedException implements Exception {
  const SasAbortedException();

  @override
  String toString() => 'SasAbortedException: SAS verification aborted';
}
