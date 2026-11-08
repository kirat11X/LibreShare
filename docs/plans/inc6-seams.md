# Increment 6 Seams & Architectural Contracts: Free Internet Rendezvous

**Document:** `docs/plans/inc6-seams.md`  
**Date:** 2026-11-06  
**Status:** Wave 0 Contract Specification

---

## 1. Directory Structure

All rendezvous logic resides in `packages/libreshare_core/lib/src/rendezvous/`:

```
packages/libreshare_core/lib/src/rendezvous/
├── bip340.dart                    # BIP-340 Schnorr signature engine on pointycastle secp256k1
├── nip01.dart                      # NIP-01 Nostr event serialization and id hashing
├── channel_deriver.dart            # Daily epoch & channel ID derivation from K_pair
├── envelope_codec.dart             # AES-256-GCM envelope encryption & length bucketing
├── records.dart                    # Sealed RendezvousRecord hierarchy and JSON codecs
├── rendezvous_backend.dart         # Abstract RendezvousBackend interface and event stream
├── nostr_backend.dart              # Multi-relay WebSocket Nostr transport implementation
├── in_memory_relay.dart            # In-process mock relay for unit and integration testing
├── presence_cache.dart             # Peer online/last-seen tracking and expiry timer
├── rendezvous_service.dart         # High-level coordinator for presence and offers
└── rendezvous_candidate_source.dart# CandidateSource adapter feeding ConnectionManager
```

---

## 2. Core Interfaces & Contracts

### 2.1 `RendezvousBackend`
```dart
abstract interface class RendezvousBackend {
  Stream<RendezvousStatus> get statusStream;
  Stream<RelayEvent> get events;

  Future<void> connect(List<Uri> relayUrls);
  Future<void> disconnect();
  Future<void> subscribe(String channelIdHex);
  Future<void> unsubscribe(String channelIdHex);
  Future<void> publish(RelayEvent event);
}
```

### 2.2 `RendezvousRecord` Hierarchy
```dart
sealed class RendezvousRecord {
  const RendezvousRecord({
    required this.seq,
    required this.issuedAt,
    this.v = 1,
  });

  final int v;
  final int seq;
  final DateTime issuedAt;

  Map<String, Object?> toJson();
}

final class PresenceRecord extends RendezvousRecord { ... }
final class ProbeRecord extends RendezvousRecord { ... }
final class OfferRecord extends RendezvousRecord { ... }
final class ReplyRecord extends RendezvousRecord { ... }
final class RevokeRecord extends RendezvousRecord { ... }
final class PairHelloRecord extends RendezvousRecord { ... }
final class PairAcceptRecord extends RendezvousRecord { ... }
```

### 2.3 `ChannelDeriver`
```dart
abstract interface class ChannelDeriver {
  int currentEpoch({DateTime? now});
  String deriveChannelId({
    required Uint8List pairKey,
    required String peerDeviceId,
    int? epoch,
  });
  Uint8List deriveEnvelopeKey({
    required Uint8List pairKey,
    int? epoch,
  });
}
```

### 2.4 `EnvelopeCodec`
```dart
abstract interface class EnvelopeCodec {
  Uint8List seal({
    required RendezvousRecord record,
    required Uint8List envelopeKey,
    required String channelIdHex,
  });

  RendezvousRecord unseal({
    required Uint8List payload,
    required Uint8List envelopeKey,
    required String channelIdHex,
  });
}
```

---

## 3. Integration Seams with Other Subsystems

1. **`DeviceRegistry` & `TrustStore`**:
   - `ContactRecord.hasPairKey`: Indicates mutual pairing status.
   - `SecretStore.get('pair:<deviceId>')`: Retrieves 32-byte $K_\text{pair}$.
2. **`ReceiveGate` Hook**:
   - `AnnouncePolicy.none`: Completely inhibits rendezvous presence publication (no traffic leaves device).
   - `AnnouncePolicy.contacts`: Publishes presence exclusively to channels derived from paired contacts in `DeviceRegistry`.
   - `AnnouncePolicy.everyone`: Does **not** broaden rendezvous scope; rendezvous never advertises to unpaired strangers.
3. **`ConnectionManager`**:
   - `RendezvousCandidateSource` supplies candidates discovered in `PresenceRecord`s (direct IPv6, mapped IPv4, and tunnel fallback) to the candidate race.
4. **Offer Consent Gate (R7)**:
   - When an `OfferRecord` arrives via rendezvous, `RendezvousService` surfaces a prompt in the UI. Under no circumstances may an incoming offer be automatically accepted.
