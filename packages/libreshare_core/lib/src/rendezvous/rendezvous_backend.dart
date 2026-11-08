// RendezvousBackend contract for transport over relays (Nostr, in-memory, ntfy).
library;

import 'dart:async';
import 'dart:typed_data';

/// Connection health status of the rendezvous backend.
enum RendezvousStatus { disconnected, connecting, connected, degraded }

/// A raw event frame published to or received from a relay.
final class RelayEvent {
  const RelayEvent({
    required this.id,
    required this.channelIdHex,
    required this.payload,
    required this.createdAt,
    this.ttlSeconds = 300,
    this.pubkeyHex = '',
    this.sigHex = '',
  });

  /// Event identifier (e.g. SHA-256 hex).
  final String id;

  /// 64-hex channel identifier tag (p-tag).
  final String channelIdHex;

  /// Encrypted ciphertext envelope bytes.
  final Uint8List payload;

  /// Creation timestamp in seconds since Unix epoch.
  final int createdAt;

  /// Expiry TTL in seconds.
  final int ttlSeconds;

  /// Author public key hex (BIP-340 or ephemeral).
  final String pubkeyHex;

  /// Cryptographic signature hex.
  final String sigHex;
}

/// Abstract contract implemented by relay adapters (Nostr WebSocket, loopback, ntfy).
abstract interface class RendezvousBackend {
  /// Stream reporting backend connection lifecycle state.
  Stream<RendezvousStatus> get statusStream;

  /// Stream delivering incoming events matching active channel subscriptions.
  Stream<RelayEvent> get events;

  /// Connects to the specified relay endpoints.
  Future<void> connect(List<Uri> relayUrls);

  /// Closes all active relay connections and releases resources.
  Future<void> disconnect();

  /// Subscribes to events tagged with [channelIdHex].
  Future<void> subscribe(String channelIdHex);

  /// Unsubscribes from events tagged with [channelIdHex].
  Future<void> unsubscribe(String channelIdHex);

  /// Publishes an event to connected relays.
  Future<void> publish(RelayEvent event);
}
