# Second Security Review: Increment 6 Card W5 (Adversarial Cryptographic Analysis)

**Reviewer:** Security Red Team Agent  
**Date:** 2026-11-08  
**Scope:** Sealed Decision Ack & Relay Redundancy (`nostr_backend.dart`, `rendezvous_service_impl.dart`)  
**Focus:** Cryptographic binding of decisions, forge resistance, and relay collusion.

---

## 1. Cryptographic Analysis of Sealed Decision Ack

### Construction
```dart
final ackHmac = hexOf(
  hmacSha256(
    kPair,
    ascii.encode('LSP-R1-DECISION:${record.offerId}:$decisionStr'),
  ),
);
```

1. **Key Separation:** Uses $K_\text{pair}$, which is shared only between the two paired peers and never revealed to relays.
2. **Context Binding:** The HMAC message prefix `LSP-R1-DECISION:` prevents cross-protocol signature substitution attacks.
3. **Offer ID & Decision Binding:** Both `offerId` (UUIDv4) and `decisionStr` ('accept' or 'decline') are explicitly bound under HMAC. An untrusted relay cannot change 'decline' to 'accept' without invalidating the 256-bit tag.
4. **Validation:** In `sendOffer`, recipient computes the identical HMAC using its local copy of $K_\text{pair}$ and verifies equality in constant time before resolving the transfer decision.

---

## 2. Multi-Relay Failover and Partitioning

1. `NostrBackend` connects to $N$ independent relays (typically 3).
2. Announcements and offers are dispatched concurrently to all connected relays.
3. An adversary controlling 1 or 2 relays cannot censor the traffic as long as 1 honest relay delivers the event.
4. Even if all 3 relays collude, they can only drop messages (DoS), but cannot forge offers, decrypt metadata, or alter transfer decisions because envelopes are protected by authenticated encryption (AES-256-GCM) and sealed decision acks.

---

## 3. Verdict

**APPROVED.** Cryptographically robust and compliant with the threat model.
