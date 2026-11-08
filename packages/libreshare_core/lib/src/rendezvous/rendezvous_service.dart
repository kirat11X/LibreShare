// RendezvousService high-level coordination contract.
library;

import 'dart:async';

import 'records.dart';

/// Callback when a transfer offer is received from a paired peer.
typedef OfferCallback = Future<bool> Function(
  String peerDeviceId,
  OfferRecord offer,
);

/// Coordinator interface for internet presence and out-of-band signaling.
abstract interface class RendezvousService {
  /// Stream emitting incoming validated presence records from paired peers.
  Stream<MapEntry<String, PresenceRecord>> get presenceEvents;

  /// Starts the rendezvous background subscriptions and presence announcements.
  Future<void> start({OfferCallback? onOffer});

  /// Stops all background timers and disconnects from relays.
  Future<void> stop();

  /// Immediately publishes presence to all paired peer channels.
  Future<void> broadcastPresence();

  /// Sends a transfer offer to [peerDeviceId] via rendezvous.
  Future<ReplyRecord> sendOffer(
    String peerDeviceId,
    OfferRecord offer, {
    Duration timeout = const Duration(seconds: 30),
  });

  /// Revokes pairing with [peerDeviceId].
  Future<void> revokePairing(String peerDeviceId);
}
