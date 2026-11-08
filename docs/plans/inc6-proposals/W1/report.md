# Card W1 Report: Channel Derivation, Envelope Codec, Replay Guard & InMemoryRelay

**Card:** W1 (Increment 6 Wave 1: Crypto Core, Length Bucketing, Replay Protection & In-Memory Relay)  
**Author:** Lead  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 24/24 tests pass x3, 5/5 mutations killed)

---

## 1. Summary of Changes
Card W1 implements the cryptographic core, discrete length bucketing, sequence replay validation, and in-memory relay harness for Increment 6 (`LSP-R1` Section 2–3 and `inc6.md` Wave 1):

1. **`ChannelDeriverImpl` (`packages/libreshare_core/lib/src/rendezvous/channel_deriver.dart`)**:
   - Implements 24-hour UTC epoch rollover: $E = \lfloor \text{unix\_ms} / (86400 \times 1000) \rfloor$.
   - Computes deterministic, unique 64-character lowercase hex channel IDs using HMAC-SHA256 bound to epoch and peer device ID.
   - Derives 32-byte AES-256-GCM envelope encryption keys using HKDF-SHA256 salted by the epoch.

2. **`EnvelopeCodecImpl` (`packages/libreshare_core/lib/src/rendezvous/envelope_codec.dart`)**:
   - Enforces discrete length bucketing across fixed boundaries ($512, 1024, 2048, 4096$ bytes) to eliminate payload size leakage.
   - Encrypts via pointycastle AES-256-GCM with a 12-byte cryptographically secure random nonce.
   - Enforces authenticated additional data (AAD) binding to `"LSP-R1:$channelIdHex"`.
   - Validates unsealing authentication tags, depads length-prefixed bytes, and deserializes records safely. Rejects tampered ciphertexts, mismatched AAD, or invalid keys with `FormatException`.

3. **`ReplayGuard` (`packages/libreshare_core/lib/src/rendezvous/replay_guard.dart`)**:
   - Enforces clock skew bounds ($\le 120$ seconds against current UTC time).
   - Enforces strictly monotonic sequence numbers (`seq`) per channel, actively preventing replay attacks.
   - Deduplicates transfer `offerId`s and probe `nonce`s across sessions.

4. **`InMemoryRelay` (`packages/libreshare_core/lib/src/rendezvous/in_memory_relay.dart`)**:
   - In-process implementation of `RendezvousBackend` for fast hermetic test suites.
   - Supports channel-level pub/sub event filtering, lifecycle status streaming, and fault injection hooks (`droppedChannels`, simulated latency).

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze --fatal-infos` passed with 0 issues.
- **Code Formatting**: `dart format --output=none --set-exit-if-changed` verified clean (0 changes).
- **Flake Gate**: 24/24 tests in `test/unit/rendezvous/` passed across 3 consecutive cycles.
- **Mutation Sweep (5/5 killed)**:
  - **M1 (Alter AAD binding in EnvelopeCodec)**: AAD mismatch fails decryption -> **KILLED** (`M1_KILLED`).
  - **M2 (Disable discrete length bucketing)**: Length assertion fails -> **KILLED** (`M2_KILLED`).
  - **M3 (Bypass clock skew check in ReplayGuard)**: Excessive skew accepted -> **KILLED** (`M3_KILLED`).
  - **M4 (Bypass monotonic sequence check in ReplayGuard)**: Replayed seq accepted -> **KILLED** (`M4_KILLED`).
  - **M5 (Bypass channel filter in InMemoryRelay)**: Unsubscribed event delivered -> **KILLED** (`M5_KILLED`).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for `channel_deriver.dart`, `envelope_codec.dart`, `replay_guard.dart`, `in_memory_relay.dart`, and barrel exports.
- `test/unit/rendezvous/wave1_test.dart`: KAT, golden, bucketing, replay, and relay tests.
- `apply-notes.md`: Instructions for orchestrator application.
- `verifier-report.md`: Independent verifier sign-off.
