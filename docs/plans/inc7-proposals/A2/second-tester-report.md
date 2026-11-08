# Second Tester Report: Card A2 (Increment 7 Wave A2)

**Card:** A2 (Increment 7 Wave A2: Secure Channel & BleSession State Machine)  
**Role:** Second Security Tester Subagent  
**Date:** 2026-11-07  
**Verdict:** PASS / CRYPTO AND SECURITY VERIFIED

---

## 1. Cryptographic Protocol Review
The implementation in `ble_crypto.dart` and `ble_session.dart` was evaluated against design 03 section 3.4 and general AEAD channel requirements:

1. **Ephemeral Key Agreement:**
   - Evaluated: P-256 ECDH via PointyCastle.
   - Finding: Ephemeral key generation uses Fortuna seeded with secure random bytes. Public keys are exported as uncompressed 65-byte points base64-encoded. Shared secret scalar is converted to a fixed 32-byte array (padLeft 64 hex chars).
2. **Transcript Binding:**
   - Evaluated: Transcript hash $th = \text{SHA256}(\text{"LSBLE1"} \parallel M1 \parallel M2)$.
   - Finding: Binds both peers' ephemeral public keys and random nonces to all subsequent operations. $th$ serves as salt for key derivation and AAD for all AEAD operations.
3. **Key Derivation:**
   - Evaluated: HKDF-SHA256 with info `"LSBLE1-keys"`.
   - Finding: Derives two distinct 32-byte keys $k_{C2P}$ and $k_{P2C}$. Directional isolation is verified.
4. **Replay & Tampering Resistance:**
   - Evaluated: AES-256-GCM with 12-byte nonce (4-byte direction || 8-byte big-endian counter).
   - Finding: Any altered tag or ciphertext byte throws `FormatException`. In `open`, counters must be strictly greater than the last received counter; replayed frames are rejected immediately.
5. **Redaction:**
   - Evaluated: `BleEphemeralKeyPair.toString()` and `BleAeadCipher.toString()`.
   - Finding: Does not leak private keys or secret keys.

---

## 2. Adversarial Security Scenarios Tested
- **Tampered M1:** Malformed base64 EPK or corrupted parameters cause Peripheral to reject handshake with `BleSecurityException`.
- **Tampered M2:** Malformed base64 EPK or invalid format causes Central to reject handshake with `BleSecurityException`.
- **Tampered AUTH Signature:** Forged/zeroed signature causes signature verification to fail and session to abort with `BleSecurityException`.
- **Wrong Peer Fingerprint:** When pinning is configured, fingerprint mismatch aborts handshake immediately before application state is exposed.
- **Replay Attack:** Capturing an encrypted application frame and re-transmitting it over the GATT stream triggers replay detection and closes the session.
- **SAS Equality:** Both peers independently compute identical 6-digit numeric SAS codes for human out-of-band verification.
