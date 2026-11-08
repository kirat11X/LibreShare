# Review: Increment 6 Card W5 (Offers Flow, Sealed Decision Ack, 3-Relay Failover)

**Reviewer:** Review Agent (independent from author)  
**Date:** 2026-11-08  
**Scope:** Card W5 (`packages/libreshare_core/lib/src/rendezvous/nostr_backend.dart`, `loopback_nostr_relay.dart`, `rendezvous_service_impl.dart`)  
**Standard:** `docs/plans/REVIEW_STANDARD.md`

---

## 1. Hunk-by-Hunk Diff Read

| Hunk / File | Description | Security & Concurrency Analysis | Verdict |
|---|---|---|---|
| `packages/libreshare_core/lib/src/rendezvous/nostr_backend.dart:7-20, 71-80` | Adds `_ephemeralSk` fallback signing key and `nip01.dart` import | Secures anonymous publishing when no long-term signing key is provided | OK |
| `nostr_backend.dart:240-275` | `publish`: checks if `event.sigHex` is present; if not, signs with `_ephemeralSk` | Ensures all published Nostr events carry cryptographically valid BIP-340 Schnorr signatures | OK |
| `loopback_nostr_relay.dart:101-180` | Adds `_safeSend` wrapping `ws.add` in `try-catch` | Prevents unhandled socket write exceptions on client disconnection or aborted connections | OK |
| `rendezvous_service_impl.dart:1-35` | Adds `relayUrls` parameter and HMAC-SHA256 import | Allows caller to pass relay URLs directly to service constructor | OK |
| `rendezvous_service_impl.dart:70-85` | `start`: connects to `relayUrls` if supplied | Establishes connections to configured relays upon startup | OK |
| `rendezvous_service_impl.dart:155-185` | Generates cryptographic `sealedAck` using `HMAC-SHA256(kPair, "LSP-R1-DECISION:$offerId:$decision")` | Prevents MITM from forging or tampering with offer accept/decline decision | OK |
| `rendezvous_service_impl.dart:285-320` | `sendOffer`: computes expected HMAC and validates `reply.sealedAck` | Rejects tampered or replayed decision acknowledgments with `LsException(LsErrorCode.authInvalid)` | OK |

---

## 2. Test Verification Against Specification (LSP-R1.md)

| Spec Requirement | Test Assertion in `wave5_test.dart` | Result |
|---|---|---|
| **LSP-R1 §4:** Sealed Decision Ack | `Offer and reply flow with valid cryptographic sealedAck succeeds` | PASS |
| **LSP-R1 §4:** Forged Decision Ack Rejection | `Forged or tampered sealedAck throws LsException(authInvalid)` | PASS |
| **LSP-R1 §6:** Multi-relay redundancy (3 relays) | `3-relay failover: one relay dies mid-wait, offer & 5 MiB transfer succeed` | PASS |

---

## 3. Mutation Testing Table

| Mutation Applied | Expected Behavior | Observed Result | Status |
|---|---|---|---|
| Omit `reply.sealedAck != expectedHmac` check in `sendOffer` | Test 2 fails: forged ack accepted without exception | Caught by test 2: expected `LsException`, received normal reply | **KILLED** |
| Tamper HMAC message string (e.g. `'LSP-R1-DECISION:$offerId'`) | Test 1 fails: valid reply rejected due to HMAC mismatch | Caught by test 1: `LsException: invalid sealed decision ack` thrown | **KILLED** |
| Omit ephemeral signature fallback in `nostr_backend.dart` | Relays rejecting unsigned events fail delivery | Caught by test 3: Nostr relays with `verifySignatures: true` drop events | **KILLED** |

---

## 4. Adversarial Edge Cases

1. **Adversary Flips Decision from Decline to Accept:** Relay operator flips `decision` field in JSON. Because `sealedAck = HMAC(kPair, "...:$decision")`, the HMAC validation on the sender side fails and the transfer is aborted.
2. **Replayed Ack for Different Offer:** Adversary copies a valid `sealedAck` from an old session. The HMAC includes `offerId`, which changes randomly per offer (`Uuid().v4()`), so the check fails.
3. **Relay Socket Closed Mid-Broadcast:** In `loopback_nostr_relay.dart`, `_safeSend` catches `SocketException` on closed client connections, preventing relay crash.
4. **Relay Dropping 1 of 3 Connections:** In `nostr_backend.dart`, `_relays` publishes to all active clients. If 1 dies, the other 2 receive the event, ensuring robust failover.
5. **Slow Relay Handshake:** `sendOffer` has a configurable `timeout` (default 30s) that cleans up `_pendingOffers` on timeout.

---

## 5. Secret & Resource Hygiene

- `kPair` is used strictly in `hmacSha256` and never exposed or logged.
- `_pendingOffers` map completers are removed on completion and on timeout.

---

## 6. Verdict

**READY FOR INTEGRATION.** Meets all criteria in `docs/plans/REVIEW_STANDARD.md`.
