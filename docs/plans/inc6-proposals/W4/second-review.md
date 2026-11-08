# Second Security Review: Increment 6 Card W4 (Adversarial Security Analysis)

**Reviewer:** Security Red Team Agent  
**Date:** 2026-11-08  
**Scope:** `presence_cache.dart`, `rendezvous_service_impl.dart`, `in_memory_relay.dart`  
**Focus:** Adversarial analysis, cryptographic boundaries, metadata leakage, replay defenses.

---

## 1. Threat Analysis

### Threat A: Metadata & Presence Leakage (Surveillance / Tracking)
- **Attack Vector:** Passive relay observer monitors pub/sub channel IDs to track whether a user is online and when they are active.
- **Defense in W4:**
  1. Inbound channels rotate every 24h UTC: `deriveChannelId(pairKey, peerDeviceId, epoch)`. Observers cannot link channel activity across days without `pairKey`.
  2. When `announcePolicy == AnnouncePolicy.none` (Receive Mode Off), `broadcastPresence()` returns immediately without publishing anything (`RelayEvent`).
  3. Relays cannot differentiate presence packets from offer or reply packets because all payloads are encrypted using AES-256-GCM with length bucket padding (256, 1024, 4096 bytes) implemented in `EnvelopeCodecImpl`.

### Threat B: Presence Spoofing & Replay Attack
- **Attack Vector:** An attacker captures an encrypted `PresenceRecord` broadcast on day $D$ and replays it later to force a peer to mark a contact as online.
- **Defense in W4:**
  1. `ReplayGuard` checks `issuedAt` against current time ($|\Delta t| \le 120\text{ s}$).
  2. `ReplayGuard` enforces monotonic sequence numbers per `channelIdHex`. Duplicate or regressive `seq` throws `ReplayException` and is dropped.
  3. `PresenceCache` entries expire after `ttl = 5 minutes`. Replaying an expired packet outside the 120-second window is rejected by `ReplayGuard`; even within the window, a duplicated `seq` is discarded.

### Threat C: Channel Flooding / DoS on Receiver
- **Attack Vector:** An adversary floods thousands of random packets to a known channel ID.
- **Defense in W4:**
  1. `_processIncoming` catches `EnvelopeCodec` unseal failures (AES-GCM tag verification failure) in a tight `try-catch` block and discards them immediately without parsing JSON or allocating state objects.
  2. Nonces are verified, bad tags never touch `ReplayGuard` or `PresenceCache`.

### Threat D: Revocation Bypass
- **Attack Vector:** A revoked peer continues to listen or inject presence.
- **Defense in W4:**
  1. `revokePairing(peerDeviceId)` immediately calls `presenceCache.evict(peerDeviceId)`.
  2. It deletes `kpair/$peerDeviceId` from `SecretStore` and clears `hasPairKey` in `TrustStore`.
  3. Future announcements to or from that peer cannot derive the channel or envelope key, rendering further communication impossible.

---

## 2. Verdict

**APPROVED.** The implementation is cryptographically sound, resistant to replay and spoofing, and adheres to zero-knowledge relay privacy requirements.
