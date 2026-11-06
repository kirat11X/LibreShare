/// Connection abstraction for the LibreShare Connection Ladder (Increment 4).
///
/// Encapsulates a bidirectional communications channel to a peer along a specific [Candidate] path.
/// Concrete subclasses implement transport-specific protocols (e.g. WiFiConnection, LANConnection,
/// and future TunnelConnection).
library;

import 'dart:async';

import '../client/peer_client.dart';
import 'candidate.dart';

/// Connection lifecycle states.
enum ConnectionState {
  /// The connection has not been opened yet, or was closed cleanly.
  disconnected,

  /// Actively establishing TCP socket and performing TLS 1.3 handshake.
  connecting,

  /// Established, certificate pinned and validated, ready for bidirectional transfer.
  connected,

  /// Terminated cleanly by either peer.
  closed,

  /// Aborted due to I/O error, handshake failure, or pinned cert mismatch.
  failed,
}

/// Abstract interface representing a physical or virtual communication channel
/// bound to a specific candidate network path.
abstract interface class Connection {
  /// The candidate network path associated with this connection.
  Candidate get candidate;

  /// Current lifecycle state of this connection.
  ConnectionState get state;

  /// Whether the channel is active, healthy, and capable of transmitting data.
  bool get isHealthy;

  /// Most recently observed round-trip latency on this connection.
  Duration? get latency;

  /// Opens the path and returns a client bound to this candidate; on the secure profile the TLS
  /// pin is candidate.peerFingerprint. A mismatch throws FingerprintMismatchException, the candidate is demoted and NEVER used.
  Future<PeerClient> open({Duration? timeout});

  /// Gracefully terminates the connection and releases socket resources.
  Future<void> close();
}

/// Base exception for connection failures and ladder transport errors.
class ConnectionException implements Exception {
  const ConnectionException(this.message, {this.candidate, this.cause});

  final String message;
  final Candidate? candidate;
  final Object? cause;

  @override
  String toString() =>
      'ConnectionException: $message'
      '${candidate != null ? ' (candidate: ${candidate!.id})' : ''}'
      '${cause != null ? ' caused by: $cause' : ''}';
}

/// Thrown when connecting, handshaking, or sending exceeds an allocated timeout budget.
class ConnectionTimeoutException extends ConnectionException {
  const ConnectionTimeoutException(
    super.message, {
    super.candidate,
    super.cause,
  });
}

/// Thrown when the remote certificate presented during TLS handshake does not match
/// the candidate's pinned [Candidate.peerFingerprint].
///
/// Security: Truncates fingerprints to 16 hex characters in toString to prevent secret leaks.
class FingerprintMismatchException extends ConnectionException {
  const FingerprintMismatchException({
    required this.expectedFingerprint,
    required this.presentedFingerprint,
    super.candidate,
  }) : super(
         'Presented certificate fingerprint does not match pinned peer identity',
       );

  final String expectedFingerprint;
  final String presentedFingerprint;

  @override
  String toString() =>
      'FingerprintMismatchException: $message '
      '(expected: ${_shortFp(expectedFingerprint)}, '
      'presented: ${_shortFp(presentedFingerprint)})';

  static String _shortFp(String fp) {
    final clean = fp.replaceAll(':', '');
    return clean.length > 16 ? clean.substring(0, 16) : clean;
  }
}
