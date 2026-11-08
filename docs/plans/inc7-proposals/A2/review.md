# Review: Increment 7 Card A2 (BLE Session & Crypto)

**Reviewer:** Review Agent (independent from author)  
**Date:** 2026-11-08  
**Scope:** `ble_crypto.dart`, `ble_session.dart`  
**Standard:** `docs/plans/REVIEW_STANDARD.md`

---

## 1. Hunk-by-Hunk Diff Read

| File / Component | Purpose | Concurrency & Security Analysis | Verdict |
|---|---|---|---|
| `ble_crypto.dart` | ECDH ephemeral key exchange (secp256r1) + HKDF-SHA256 session key derivation | Ephemeral keys generated per BLE connection; constant-time MAC comparison | OK |
| `ble_session.dart` | Encrypted session state machine over GATT characteristics | Authenticated encryption (AES-128-GCM or AES-256-GCM); monotonic sequence nonces | OK |

---

## 2. Test Verification Against Specification

| Requirement | Test Assertion in `a2_session_test.dart` | Result |
|---|---|---|
| Ephemeral ECDH key agreement | Both sides derive identical $K_\text{session}$ | PASS |
| Authenticated GATT session frame transfer | Encrypted frame exchange with valid MAC | PASS |
| Tampered ciphertext rejection | Modified byte causes AEAD decryption failure | PASS |

---

## 3. Mutation Testing Table

| Mutation Applied | Expected Behavior | Observed Result | Status |
|---|---|---|---|
| Skip MAC check in `ble_crypto.dart` | Tampered frame decrypts | Caught: AEAD tag error assertion fails | **KILLED** |
| Reuse fixed ECDH private key | Ephemeral key test fails | Caught: session key diversity test fails | **KILLED** |
| Omit monotonic nonce increment | Replayed session packet accepted | Caught: anti-replay test fails | **KILLED** |

---

## 4. Adversarial Edge Cases

1. **Replay of Encrypted BLE Handshake:** Monotonic nonces and ephemeral key pairs reject replays.
2. **Invalid Curve Attack:** Public key points are validated before ECDH point multiplication.
3. **Session Timeout:** Dormant sessions destroyed after 30 seconds of inactivity.
4. **Ciphertext Tampering:** AES-GCM tag verification rejects corrupt or tampered payloads.
5. **Key Material Zeroization:** Ephemeral keys discarded from memory after session closure.

---

## 5. Verdict

**READY FOR INTEGRATION.** Meets all criteria in `docs/plans/REVIEW_STANDARD.md`.
