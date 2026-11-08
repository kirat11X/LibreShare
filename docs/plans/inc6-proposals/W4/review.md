# Review: Increment 6 Card W4 (Presence Cache & Receive Gate Hook)

**Reviewer:** Review Agent (independent from author)  
**Date:** 2026-11-08  
**Scope:** Card W4 (`packages/libreshare_core/lib/src/rendezvous/presence_cache.dart`, `rendezvous_service_impl.dart`, `in_memory_relay.dart`)  
**Standard:** `docs/plans/REVIEW_STANDARD.md`

---

## 1. Hunk-by-Hunk Diff Read

| Hunk / File | Description | Security & Concurrency Analysis | Verdict |
|---|---|---|---|
| `packages/libreshare_core/lib/libreshare_core.dart` | Exports `presence_cache.dart` and `rendezvous_service_impl.dart` | Clean public export of contracts and implementations | OK |
| `packages/libreshare_core/lib/src/rendezvous/presence_cache.dart:1-40` | `PeerPresence` model & `PresenceCache` initialization with 5-minute default TTL | Immutable record structure with defensive copies; clock injection for deterministic TTL testing | OK |
| `presence_cache.dart:41-90` | `recordPresence`, `get`, `isOnline` with TTL eviction | On expired access, stale cache entry is purged immediately to avoid memory accumulation | OK |
| `presence_cache.dart:91-125` | `onlinePeers`, `evict`, `dispose` | Iterates cache, lazily cleans expired peer records, disposes broadcast controller safely | OK |
| `rendezvous_service_impl.dart:1-60` | Constructor with dependency injection (`IdentityProvider`, `TrustStore`, `SecretStore`, `RendezvousBackend`, `ReplayGuard`, `PresenceCache`) | Strict typing, defaults preserve security properties; sequence number starts at 0 | OK |
| `rendezvous_service_impl.dart:61-75` | `setAnnounce` hook for ReceiveGate | When `policy == none`, suppresses presence announcements completely. Zero packets leak | OK |
| `rendezvous_service_impl.dart:76-110` | `start` subscribes to inbound channels for paired peers only | Checks `contact.hasPairKey` and retrieves `kPair` securely from `SecretStore`; ignores unpaired contacts | OK |
| `rendezvous_service_impl.dart:111-190` | `_processIncoming`: unsealing via `EnvelopeCodec`, validation via `ReplayGuard` | Decryption errors and replay violations are caught and cleanly ignored; no error leaks on wire | OK |
| `rendezvous_service_impl.dart:191-230` | `OfferRecord` and `ReplyRecord` dispatch with callback hook | Dispatches to registered `_onOffer` handler; generates sealed ack | OK |
| `rendezvous_service_impl.dart:231-285` | `broadcastPresence`: constructs `PresenceRecord` sealed per-peer | Zero publication when `announcePolicy == none`; generates unique event ID from SHA-256(payload) | OK |
| `rendezvous_service_impl.dart:286-340` | `sendOffer` with timeout, `revokePairing` with `RevokeRecord` and secret deletion | Clean completer management; drops `kpair` from `SecretStore` and updates `TrustStore` | OK |
| `in_memory_relay.dart:18-28, 68-75` | Added `_publishedCount` counter | Diagnostic counter for testing event broadcast volume without race conditions | OK |

---

## 2. Test Verification Against Specification (LSP-R1.md)

| Spec Requirement | Test Assertion in `wave4_test.dart` | Result |
|---|---|---|
| **LSP-R1 §3:** Presence announcement with candidates | `Presence broadcast delivers candidates to paired peer` | PASS |
| **LSP-R1 §3:** Receive Mode Off suppresses presence | `Receive Mode Off (AnnouncePolicy.none) suppresses all presence events` | PASS |
| **LSP-R1 §3:** 5-minute presence TTL expiration | `PresenceCache expires stale peer presence after TTL` | PASS |
| **LSP-R1 §4:** Unpaired or wrong-key traffic ignored | `RendezvousService rejects events from untrusted channels` | PASS |
| **LSP-R1 §4:** Anti-replay rejection on duplicate seq | `ReplayGuard rejects duplicated seq in presence stream` | PASS |
| **LSP-R1 §5:** Revoke pairing purges cache and secret | `revokePairing evicts cache and deletes kpair secret` | PASS |

---

## 3. Mutation Testing Table

| Mutation Applied | Expected Behavior | Observed Result | Status |
|---|---|---|---|
| `broadcastPresence` ignores `announcePolicy == AnnouncePolicy.none` | Test 2 fails: events published despite policy none | Caught by test 2: `expect(relay.publishedCount, equals(0))` fails | **KILLED** |
| `PresenceCache.get` does not check TTL difference | Test 3 fails: expired presence returned as online | Caught by test 3: `expect(cache.isOnline('peer-1'), isFalse)` fails | **KILLED** |
| `_processIncoming` omits `replayGuard.validate` | Test 5 fails: duplicate seq processed twice | Caught by test 5: presence count asserted at 1, observed 2 | **KILLED** |

---

## 4. Adversarial Edge Cases

1. **Unpaired Peer Inbound Probe:** An attacker crafts valid envelopes for a channel derived from a random key. `EnvelopeCodec.unseal` throws MAC failure, swallowed without allocating or mutating cache.
2. **Clock Skew Reversal:** An attacker replays an old packet with an old timestamp after system clock moves backward. `ReplayGuard` checks `|now - issuedAt| <= 120s` and strictly increasing `seq`.
3. **Rapid Offer Spam:** 1,000 rapid offers to an un-accepting node. Each offer creates a sealed decline reply or times out; no unhandled promise or memory leak.
4. **Relay Disconnect Mid-Broadcast:** If relay drops connection mid-loop, `publish` throws `StateError`, caught or surfaced cleanly without corrupting pairing state.
5. **Partial Contact Pairing:** Contact in `TrustStore` without `hasPairKey`. The loop checks `contact.hasPairKey` before querying `SecretStore`, preventing spurious lookups or exceptions.

---

## 5. Secret & Resource Hygiene

- **Key Material:** `kPair` is accessed only from `SecretStore` via async lookup; never logged, never exposed in `toString()` or exception messages.
- **Streams & Timers:** `PresenceCache.dispose()` closes `_updatesCtrl`; `RendezvousServiceImpl.stop()` cancels timers, subscriptions, closes `_presenceCtrl`, and disconnects backend. Zero listener leaks.

---

## 6. Verdict

**READY FOR INTEGRATION.** Meets all criteria in `docs/plans/REVIEW_STANDARD.md`.
