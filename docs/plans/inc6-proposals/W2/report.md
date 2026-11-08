# Card W2 Report: BIP-340 Schnorr, NIP-01 Codec, LoopbackNostrRelay & NostrBackend Failover

**Card:** W2 (Increment 6 Wave 2: BIP-340 Engine, NIP-01 Events, Multi-Relay Transport & Failover)  
**Author:** Lead  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 29/29 tests pass x3, 5/5 mutations killed)

---

## 1. Summary of Changes
Card W2 implements the pure-Dart BIP-340 Schnorr cryptography engine, NIP-01 event format, WebSocket multi-relay failover transport, and an in-process loopback relay harness for Increment 6:

1. **`bip340.dart` (`packages/libreshare_core/lib/src/rendezvous/bip340.dart`)**:
   - Pure-Dart implementation of BIP-340 Schnorr signatures over secp256k1 using existing `pointycastle 4.0.0` primitives.
   - Computes tagged hashes (`BIP0340/aux`, `BIP0340/nonce`, `BIP0340/challenge`).
   - Supports 32-byte $x$-only public key derivation, signing with auxiliary randomness, and signature verification via point multiplication.

2. **`nip01.dart` (`packages/libreshare_core/lib/src/rendezvous/nip01.dart`)**:
   - Implements canonical NIP-01 event serialization (`[0, pubkey, created_at, kind, tags, content]`) and SHA-256 event ID generation.
   - Signs event IDs with `signBip340` and verifies event authenticity with `verifyBip340`.

3. **`LoopbackNostrRelay` (`packages/libreshare_core/lib/src/rendezvous/loopback_nostr_relay.dart`)**:
   - In-process HTTP/WebSocket relay server running on `127.0.0.1` with ephemeral OS-allocated ports.
   - Upgrades connections via `WebSocketTransformer.upgrade`, serves NIP-11 information documents, parses NIP-01 messages (`EVENT`, `REQ`, `CLOSE`), verifies BIP-340 event signatures, and delivers matching events to subscriber WebSockets.
   - Supports test hooks: abrupt connection cut (`killMidRun`) and hostile oversized frame injection (> 128 KiB).

4. **`NostrBackend` (`packages/libreshare_core/lib/src/rendezvous/nostr_backend.dart`)**:
   - Multi-relay WebSocket client connecting to multiple relays simultaneously.
   - Multiplexes subscriptions, republishes across all healthy relays, and tracks connection health (`connected` vs `degraded` vs `disconnected`).
   - Automatically deduplicates incoming events delivered by multiple relays using an LRU cache.
   - Implements safety clamp: drops incoming frames exceeding 128 KiB without crashing.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze --fatal-infos` passed with 0 issues.
- **Code Formatting**: `dart format --output=none --set-exit-if-changed` verified clean (0 changes).
- **Flake Gate**: 29/29 tests in `test/unit/rendezvous/` passed across 3 consecutive cycles.
- **Mutation Sweep (5/5 killed)**:
  - **M1 (Bypass BIP-340 signature verification)**: Verification fails -> **KILLED** (`M1_KILLED`).
  - **M2 (Skip NIP-01 signature check)**: Tampered event content fails verification -> **KILLED** (`M2_KILLED`).
  - **M3 (Suppress status degradation on relay death)**: Status assertion fails -> **KILLED** (`M3_KILLED`).
  - **M4 (Remove frame safety clamp)**: Oversized frame test fails -> **KILLED** (`M4_KILLED`).
  - **M5 (Duplicate events delivered across multiple relays)**: Count assertion fails -> **KILLED** (`M5_KILLED`).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for `bip340.dart`, `nip01.dart`, `loopback_nostr_relay.dart`, and `nostr_backend.dart`.
- `test/unit/rendezvous/wave2_test.dart`: Signature verification, serialization, multi-relay failover, and safety clamp tests.
- `apply-notes.md`: Instructions for orchestrator application.
- `verifier-report.md`: Independent verifier sign-off.
