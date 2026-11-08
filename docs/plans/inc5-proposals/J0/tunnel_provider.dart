import 'dart:async';

/// Abstract interface for a tunnel or reverse proxy provider that exposes
/// a local HTTP origin to an external public address.
abstract interface class TunnelProvider {
  /// Unique provider identifier ('cloudflare-quick', 'zrok', 'manual-url', 'fake').
  String get id;

  /// Returns true if the provider is operational and available on this machine
  /// (e.g. pinned helper binary is installed or token is set).
  Future<bool> isAvailable();

  /// Starts or opens a tunnel to [localPort] on loopback.
  /// Throws if the tunnel cannot be established within [ready].
  Future<TunnelHandle> open(
    int localPort, {
    Duration ready = const Duration(seconds: 45),
  });
}

/// Active handle to an open tunnel connection.
abstract interface class TunnelHandle {
  /// The public base URI (e.g. `https://random-subdomain.trycloudflare.com`).
  /// Never contains path or secret tokens.
  Uri get publicBase;

  /// Stream of operational and lifecycle events for this tunnel.
  Stream<TunnelEvent> get events;

  /// Gracefully tears down and terminates the tunnel.
  Future<void> close();
}

/// Events emitted during the lifecycle of a tunnel.
sealed class TunnelEvent {
  const TunnelEvent();
}

/// The tunnel is connected and actively forwarding requests.
final class TunnelUpEvent extends TunnelEvent {
  const TunnelUpEvent();
  @override
  String toString() => 'TunnelUpEvent()';
}

/// The tunnel connection was lost or terminated.
final class TunnelLostEvent extends TunnelEvent {
  final String reason;
  const TunnelLostEvent(this.reason);
  @override
  String toString() => 'TunnelLostEvent($reason)';
}

/// The tunnel provider indicated rate limiting (e.g. HTTP 429 / 1015).
final class TunnelRateLimitedEvent extends TunnelEvent {
  final Duration? retryAfter;
  const TunnelRateLimitedEvent([this.retryAfter]);
  @override
  String toString() => 'TunnelRateLimitedEvent(retryAfter: $retryAfter)';
}

/// Scrubbed diagnostic log output from the tunnel supervisor.
final class TunnelLogEvent extends TunnelEvent {
  final String line;
  const TunnelLogEvent(this.line);
  @override
  String toString() => 'TunnelLogEvent($line)';
}
