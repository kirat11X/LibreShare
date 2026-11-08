# Card W5 Report: Offers, Sealed Decision Ack & Multi-Relay Internet Transfer

**Card:** W5 (Increment 6 Wave 5: Offers, Sealed Decision Ack, 3-Relay Failover & 5 MiB Transfer)  
**Author:** Lead  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 3/3 tests pass x3, 3/3 mutations killed)

---

## 1. Summary of Changes
Card W5 implements the offer and sealed decision ack signaling flow and verifies resilience across multi-relay failovers:

1. **Offers & Cryptographic Sealed Decision Ack (`rendezvous_service_impl.dart`)**:
   - `sendOffer`: Formulates encrypted `OfferRecord` carrying manifest and tunnel/direct candidates.
   - **Rule R7 (No Auto-Accept)**: Receiver prompts user via `onOffer` callback. Explicit decision ('accept' or 'decline') is required.
   - Sealed decision ack: Receiver derives HMAC-SHA256($K_\text{pair}$, `"LSP-R1-DECISION:"` $\parallel \text{offerId} \parallel \text{decision}$) as non-repudiable proof of user consent.
   - Sender validates `sealedAck` HMAC upon reply arrival; forged or tampered acks are rejected with `authInvalid`.

2. **Decentralized Nostr Multi-Relay Failover (`nostr_backend.dart` & `loopback_nostr_relay.dart`)**:
   - `NostrBackend` signs outgoing events with BIP-340 Schnorr signatures if not already signed, guaranteeing valid NIP-01 framing.
   - In-process `LoopbackNostrRelay` hardened with `_safeSend` guards against abrupt socket closure.
   - Verified across 3 active loopback relays: when 1 relay is killed mid-run, communication fails over to remaining healthy relays without packet or message loss.
   - Simulated 5 MiB file transfer verified byte-identical by SHA-256 hash.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze --fatal-infos packages/libreshare_core/lib/src/rendezvous/ packages/libreshare_core/test/unit/rendezvous/` -> 0 issues.
- **Code Formatting**: `dart format --output=none --set-exit-if-changed` verified clean (0 changes).
- **Flake Gate**: 3/3 tests passed across 3 consecutive cycles.
- **Mutation Sweep (3/3 killed)**:
  - **M1 (Bypass sealed decision ack validation)**: `tampered sealed decision ack is rejected with authInvalid` fails -> **KILLED** (`M1_KILLED`).
  - **M2 (Auto-accept offers without prompting user)**: `Offer flow generates and verifies cryptographic sealed decision ack` prompt check fails -> **KILLED** (`M2_KILLED`).
  - **M3 (Publish only to first relay instead of multi-relay broadcast)**: `3-relay failover: one relay dies mid-wait, offer & 5 MiB transfer succeed` times out -> **KILLED** (`M3_KILLED`).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for `nostr_backend.dart`, `loopback_nostr_relay.dart`, and `rendezvous_service_impl.dart`.
- `test/wave5_test.dart`: Offer signaling, sealed ack validation, 3-relay failover, and simulated 5 MiB transfer tests.
- `apply-notes.md`: Application instructions for orchestrator.
- `verifier-report.md`: Independent verifier sign-off.
