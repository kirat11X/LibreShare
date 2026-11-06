/// Channel and connection ladder events for the LibreShare monitor subsystem (Increment 4).
///
/// Emitted during candidate probing, channel promotion, failure detection, and tier fallback.
/// These events feed [StatusMonitor], [EventLog], and app UI indicators (Wi-Fi / LAN badges).
library;

import 'candidate.dart';

/// Base sealed class for all connection ladder and transport channel lifecycle events.
sealed class ChannelEvent {
  const ChannelEvent({required this.timestamp});

  /// Timestamp when this event was recorded.
  final DateTime timestamp;
}

/// Emitted when a candidate channel successfully completes its TLS handshake
/// and becomes the primary active transport for a session.
class ChannelActive extends ChannelEvent {
  const ChannelActive({
    required this.candidate,
    this.sessionId,
    required this.rtt,
    required super.timestamp,
  });

  /// Active candidate chosen for data transmission.
  final Candidate candidate;

  /// Optional session identifier associated with this channel.
  final String? sessionId;

  /// Round-trip time measured during connection activation.
  final Duration rtt;

  @override
  String toString() =>
      'ChannelActive(candidate: ${candidate.id}, tier: ${candidate.kind.wire}, '
      'rtt: ${rtt.inMilliseconds}ms, sid: $sessionId)';
}

/// Emitted when an active channel or candidate connection fails.
class ChannelFailed extends ChannelEvent {
  const ChannelFailed({
    required this.candidate,
    this.sessionId,
    required this.reason,
    this.error,
    this.consecutiveFailures = 1,
    required super.timestamp,
  });

  /// The candidate whose channel failed.
  final Candidate candidate;

  /// Associated session identifier, if bound.
  final String? sessionId;

  /// Human-readable diagnosis or failure category.
  final String reason;

  /// Underlying error or exception, if any.
  final Object? error;

  /// Number of consecutive chunk or probe failures observed on this channel.
  final int consecutiveFailures;

  @override
  String toString() =>
      'ChannelFailed(candidate: ${candidate.id}, reason: $reason, '
      'failures: $consecutiveFailures, sid: $sessionId)';
}

/// Emitted when the connection ladder switches from one candidate/tier to another.
///
/// For example, falling back from Wi-Fi (Tier 1) to LAN (Tier 2) after 3 consecutive failures.
class ChannelTierSwitched extends ChannelEvent {
  const ChannelTierSwitched({
    this.sessionId,
    this.fromCandidate,
    required this.toCandidate,
    required this.reason,
    required super.timestamp,
  });

  /// Associated session identifier, if bound.
  final String? sessionId;

  /// The previous candidate channel that failed or was demoted, if known.
  final Candidate? fromCandidate;

  /// The new candidate promoted to active channel.
  final Candidate toCandidate;

  /// Operational cause for switching tiers (e.g. "consecutive_chunk_failures", "probe_timeout").
  final String reason;

  @override
  String toString() =>
      'ChannelTierSwitched(from: ${fromCandidate?.id ?? "none"} [${fromCandidate?.kind.wire ?? "none"}] -> '
      'to: ${toCandidate.id} [${toCandidate.kind.wire}], reason: $reason, sid: $sessionId)';
}

/// Emitted when a candidate is tested during background health checking, racing, or probing.
class ChannelCandidateTested extends ChannelEvent {
  const ChannelCandidateTested({
    required this.candidate,
    required this.success,
    this.rtt,
    this.error,
    required super.timestamp,
  });

  /// Candidate that was probed.
  final Candidate candidate;

  /// Whether the probe or test connection succeeded.
  final bool success;

  /// Measured latency if successful.
  final Duration? rtt;

  /// Diagnostic failure description if probe failed.
  final String? error;

  @override
  String toString() =>
      'ChannelCandidateTested(candidate: ${candidate.id}, success: $success, '
      'rtt: ${rtt?.inMilliseconds}ms${error != null ? ", error: $error" : ""})';
}
