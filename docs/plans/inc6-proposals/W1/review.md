# Review: Card W1 (Channel Deriver, Envelope Codec, Replay Guard & In-Memory Relay)

**Reviewer:** Antigravity Independent Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc6-proposals/W1/`  
**Verdict:** ACCEPT  

---

## 1. Scope
- **Files added/changed in `patch.diff`:** (5 files, matches `grep -c '^--- ' patch.diff` = 5)
  1. `packages/libreshare_core/lib/src/rendezvous/channel_deriver.dart`
  2. `packages/libreshare_core/lib/src/rendezvous/envelope_codec.dart`
  3. `packages/libreshare_core/lib/src/rendezvous/replay_guard.dart`
  4. `packages/libreshare_core/lib/src/rendezvous/in_memory_relay.dart`
  5. `packages/libreshare_core/lib/libreshare_core.dart`
- **Test files:**
  1. `packages/libreshare_core/test/unit/rendezvous/wave1_test.dart`
- **Spec / Plan references:**
  - `docs/plans/inc6.md` Section 1, 4 (Wave 1: `channel_deriver`, `envelope_codec`, signing/replay rules, `InMemoryRelay`)
  - `docs/protocol/LSP-R1.md` Section 2.1-2.4 (Channel derivation, envelope encryption, padding buckets, replay protection)

---

## 2. Diff Read
- `channel_deriver.dart` (lines 1-70): Implements daily 24h UTC epoch derivation, 64-hex channel ID derivation via HMAC-SHA256, and envelope key derivation via HKDF-SHA256. **Verdict: OK (Security-Critical).**
- `envelope_codec.dart` (lines 1-177): Implements AES-256-GCM AEAD encryption bound to channel ID in AAD. Pads payloads into discrete buckets (256, 1024, 4096 bytes) to conceal record type and size from untrusted relay operators. Throws `FormatException` on tampered ciphertext or AAD. **Verdict: OK (Security-Critical).**
- `replay_guard.dart` (lines 1-92): Validates record freshness against timestamp skew threshold (|now - issuedAt| <= 120s) and monotonic sequence numbers per peer (`seq > highestSeen`). Drops replays and out-of-order stale packets. **Verdict: OK (Security-Critical).**
- `in_memory_relay.dart` (lines 1-107): Hermetic in-process implementation of `RelayBackend` for unit and integration testing. **Verdict: OK.**
- `libreshare_core.dart`: Exports `replay_guard.dart` and `in_memory_relay.dart`. **Verdict: OK.**

---

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Epoch Boundary Derivation | `currentEpoch derives consistent 24h UTC boundaries` | Proves transition occurs at 00:00:00 UTC and increments epoch integer. |
| Deterministic Channel & Key Derivation | `deriveChannelId and deriveEnvelopeKey are deterministic and distinct` | Proves identical pair keys and device IDs yield identical channels, while different epochs yield disjoint channels. |
| Envelope AEAD & Padding Bucket Concealment | `seal and unseal roundtrip with padding bucket verification` | Proves small payloads are padded to minimum 256 bytes and unsealed byte-for-byte. |
| AAD Channel Binding Enforcement | `unseal rejects ciphertext when channelIdHex AAD mismatches` | Proves ciphertext relayed to wrong channel cannot be decrypted. |
| Replay Guard Monotonic Ordering | `validate rejects non-monotonic sequence numbers` | Proves `seq <= highest_seen_seq` is dropped immediately. |
| Timestamp Skew Bounding | `validate rejects timestamps skewed by > 120s` | Proves records older than 120s or in the future by > 120s are dropped. |

---

## 4. Mutation Table
| Mutation Description | Target File / Line | Red Test Result | Post-Restore Diff |
|---|---|---|---|
| Invert channel ID epoch check in `deriveChannelId` | `channel_deriver.dart:45` | `wave1_test.dart` FAIL (epoch divergence unhandled) | clean (`diff -r` rc=0) |
| Remove channel ID from AES-GCM AAD in `seal` | `envelope_codec.dart:88` | `wave1_test.dart` FAIL (channel binding check fails) | clean (`diff -r` rc=0) |
| Allow equal sequence numbers (`seq >= highest`) in `validate` | `replay_guard.dart:42` | `wave1_test.dart` FAIL (replayed sequence accepted) | clean (`diff -r` rc=0) |
| Increase timestamp skew tolerance from 120s to 300s | `replay_guard.dart:18` | `wave1_test.dart` FAIL (stale 150s record accepted) | clean (`diff -r` rc=0) |

---

## 5. Adversarial Cases Tried
1. **Tampered Ciphertext:** Bit flipped in AES-GCM ciphertext payload. `unseal()` throws `FormatException` on AEAD tag verification failure.
2. **Channel Cross-Injection (Replay to Different Channel):** Valid ciphertext sent to channel $C_1$ is re-published by malicious relay to channel $C_2$. `unseal()` detects AAD mismatch and rejects the packet.
3. **Out-of-Order Sequence Flooding:** Attacker sends `seq=100`, then replays `seq=50`. Guard drops `seq=50`.
4. **Extreme Future Timestamp (Clock Drift):** Attacker injects timestamp 1 year in the future. Guard rejects packet due to `skew > 120s`.
5. **Padding Corruption:** Corrupted length prefix in padded buffer throws `FormatException` without allocating memory.

---

## 6. Resource and Failure Behaviour
- `InMemoryRelay.close()` cleanly closes all internal `StreamController` instances.
- Zero secrets (`S`, `K_pair`, `K_env`) are rendered in `toString()` or logs.

---

## 7. Compatibility
- Patch applies cleanly to tree + K0..K5 + W0: `git apply --check -p1 docs/plans/inc6-proposals/W1/patch.diff` (rc=0).
- Pure Dart, all tests execute in-process without network sockets.

---

## 8. Verdict
**ACCEPT**

### What the final deep review must re-check:
- Ensure `ReplayGuard` instances are properly persisted or reset safely across engine reboots.
