// PresenceCache tracking peer presence, freshness TTL, and active candidates.
library;

import 'dart:async';

import '../clock.dart';
import '../connection/candidate.dart';
import 'records.dart';
import 'rendezvous_candidate_source.dart';

/// Information about a paired peer's online presence and reachable candidates.
class PeerPresence {
  const PeerPresence({
    required this.peerDeviceId,
    required this.lastSeen,
    required this.isOnline,
    required this.record,
    required this.candidates,
  });

  final String peerDeviceId;
  final DateTime lastSeen;
  final bool isOnline;
  final PresenceRecord record;
  final List<Candidate> candidates;
}

/// Cache storing presence information for paired peers.
class PresenceCache {
  PresenceCache({
    this.ttl = const Duration(minutes: 5),
    this.clock = const SystemClock(),
    this.candidateSource = const RendezvousCandidateSource(),
  });

  final Duration ttl;
  final Clock clock;
  final RendezvousCandidateSource candidateSource;

  final Map<String, PeerPresence> _cache = {};
  final StreamController<PeerPresence> _updatesCtrl =
      StreamController<PeerPresence>.broadcast();

  /// Stream of presence updates as peers announce or change status.
  Stream<PeerPresence> get updates => _updatesCtrl.stream;

  /// Updates or records presence for [peerDeviceId].
  void recordPresence(
    String peerDeviceId,
    PresenceRecord record, {
    String peerFingerprint = '',
  }) {
    final now = clock.now();
    final candidates = candidateSource.candidatesFromPresence(
      presence: record,
      peerFingerprint: peerFingerprint,
    );

    final presence = PeerPresence(
      peerDeviceId: peerDeviceId,
      lastSeen: now,
      isOnline: true,
      record: record,
      candidates: candidates,
    );

    _cache[peerDeviceId] = presence;
    _updatesCtrl.add(presence);
  }

  /// Returns current presence for [peerDeviceId], or null if unknown or expired.
  PeerPresence? get(String peerDeviceId) {
    final entry = _cache[peerDeviceId];
    if (entry == null) return null;
    if (clock.now().difference(entry.lastSeen) > ttl) {
      _cache.remove(peerDeviceId);
      return null;
    }
    return entry;
  }

  /// Whether [peerDeviceId] is currently considered online.
  bool isOnline(String peerDeviceId) => get(peerDeviceId) != null;

  /// Returns list of all peers currently online within TTL.
  List<PeerPresence> get onlinePeers {
    final now = clock.now();
    final result = <PeerPresence>[];
    final expiredKeys = <String>[];

    for (final entry in _cache.entries) {
      if (now.difference(entry.value.lastSeen) <= ttl) {
        result.add(entry.value);
      } else {
        expiredKeys.add(entry.key);
      }
    }

    for (final k in expiredKeys) {
      _cache.remove(k);
    }

    return result;
  }

  /// Manually evicts a peer (e.g. on unpair/revoke).
  void evict(String peerDeviceId) {
    _cache.remove(peerDeviceId);
  }

  /// Disposes resources.
  Future<void> dispose() async {
    await _updatesCtrl.close();
  }
}
