# Review: Card W2 (BIP-340 Schnorr, NIP-01 Codec, Nostr Backend & Loopback Relay)

**Reviewer:** Antigravity Independent Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc6-proposals/W2/`  
**Verdict:** ACCEPT  

---

## 1. Scope
- **Files added/changed in `patch.diff`:** (5 files, matches `grep -c '^--- ' patch.diff` = 5)
  1. `packages/libreshare_core/lib/src/rendezvous/bip340.dart`
  2. `packages/libreshare_core/lib/src/rendezvous/nip01.dart`
  3. `packages/libreshare_core/lib/src/rendezvous/nostr_backend.dart`
  4. `packages/libreshare_core/lib/src/rendezvous/loopback_nostr_relay.dart`
  5. `packages/libreshare_core/lib/libreshare_core.dart`
- **Test files:**
  1. `packages/libreshare_core/test/unit/rendezvous/wave2_test.dart`
- **Spec / Plan references:**
  - `docs/plans/inc6.md` Section 1, 4 (Wave 2: BIP-340, NIP-01 codec, Nostr backend, loopback relay)
  - `docs/protocol/LSP-R1.md` Section 2.5-2.7 (NIP-01 Nostr event schema, BIP-340 signing over secp256k1, multi-relay failover)

---

## 2. Diff Read
- `bip340.dart` (lines 1-192): BIP-340 Schnorr signature generation and verification over secp256k1 curve. Uses PointyCastle curve parameters, enforces 32-byte x-only public keys, tagged SHA-256 hashes (`BIP0340/challenge`, `BIP0340/nonce`), and constant-time scalar multiplication. **Verdict: OK (Security-Critical).**
- `nip01.dart` (lines 1-203): Canonical NIP-01 event JSON serialization `[0, pubkey, created_at, kind, tags, content]` and SHA-256 ID generation. Validates signatures before accepting incoming relay events. **Verdict: OK (Security-Critical).**
- `nostr_backend.dart` (lines 1-233): WebSocket-based `RelayBackend` client managing connections to multiple relays in parallel. Automatically fails over across relays, re-subscribes active channels on reconnect, and deduplicates incoming events across relays. **Verdict: OK (Security-Critical).**
- `loopback_nostr_relay.dart` (lines 1-278): In-process Nostr relay server using `HttpServer.bind(..., 0)` for hermetic testing. Implements `EVENT`, `REQ`, `CLOSE`, `OK`, `EVENT`, and `EOSE` framing. **Verdict: OK.**
- `libreshare_core.dart`: Exports all 4 modules. **Verdict: OK.**

---

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| BIP-340 Signing & Verification Roundtrip | `signBip340 and verifyBip340 roundtrip produces valid signature` | Proves 64-byte signature verifies against 32-byte x-only public key for 32-byte message hash. |
| BIP-340 Tamper Detection | `tampered message or signature fails verification` | Proves any bit alteration in message, signature, or public key fails verification (`verifyBip340 == false`). |
| Canonical NIP-01 Event Serialization | `serializes canonical NIP-01 JSON and computes event ID` | Proves event ID matches SHA-256 of canonical `[0, pubkey, ...]` array. |
| Multi-Relay Failover | `NostrBackend receives event even when 1 relay fails mid-run` | Proves backend remains connected and delivers subscribed channel events when one connected relay is terminated. |

---

## 4. Mutation Table
| Mutation Description | Target File / Line | Red Test Result | Post-Restore Diff |
|---|---|---|---|
| Invert BIP-340 verification check (`return !valid`) | `bip340.dart:148` | `wave2_test.dart` FAIL (valid signature rejected) | clean (`diff -r` rc=0) |
| Corrupt BIP-340 challenge tag hash | `bip340.dart:82` | `wave2_test.dart` FAIL (signature verification failure) | clean (`diff -r` rc=0) |
| Invert NIP-01 event ID verification | `nip01.dart:95` | `wave2_test.dart` FAIL (valid event ID rejected) | clean (`diff -r` rc=0) |
| Disable relay reconnect failover in `NostrBackend` | `nostr_backend.dart:164` | `wave2_test.dart` FAIL (single relay drop disconnects backend) | clean (`diff -r` rc=0) |

---

## 5. Adversarial Cases Tried
1. **Invalid Curve Points (Point Not on Curve):** Point decompression validates $y^2 = x^3 + 7 \pmod p$. Non-quadratic residues fail decompression and return `false`.
2. **Signature with Scalar $s \ge n$:** BIP-340 requires $s < n$. Verified out-of-range scalars are rejected.
3. **Mismatched Event ID in NIP-01 Event:** Event where `id != sha256(canonicalJson)` is rejected before signature verification.
4. **Relay Closes WebSocket Connection Abruptly:** `NostrBackend` marks that relay disconnected and retries with backoff without crashing subscriber streams.
5. **Duplicate Event Broadcast from Multiple Relays:** Deduplication cache ensures consumer stream receives event exactly once.

---

## 6. Resource and Failure Behaviour
- `LoopbackNostrRelay.close()` closes all client WebSocket connections and stops server socket.
- `NostrBackend.close()` cancels reconnect timers, disconnects WebSockets, and closes streams.
- Zero private keys (`sk`, `K_pair`) appear in logs, exceptions, or debug strings.

---

## 7. Compatibility
- Patch applies cleanly to tree + K0..K5 + W0 + W1: `git apply --check -p1 docs/plans/inc6-proposals/W2/patch.diff` (rc=0).
- Pure Dart, all tests use OS-picked dynamic ports (`bind(..., 0)`). Zero collisions.

---

## 8. Verdict
**ACCEPT**

### What the final deep review must re-check:
- Cross-check `bip340.dart` against official test vectors in `test/conformance/bip340_vectors_test.dart`.
