# Second Security Review: Increment 7 Card A2 (BLE Session Cryptography Analysis)

**Reviewer:** Security Red Team Agent  
**Date:** 2026-11-08  
**Scope:** `ble_crypto.dart`, `ble_session.dart`  
**Focus:** BLE link-layer eavesdropping, MITM attacks, forward secrecy.

---

## 1. Cryptographic Analysis

1. **Forward Secrecy:**
   - Every BLE pairing handshake exchanges fresh ephemeral P-256 public keys ($pk_A, pk_B$).
   - Session keys are derived via `HKDF-SHA256(ikm = ECDH(sk, pk), salt = nonce_A || nonce_B, info = "LSP-BLE-V1")`.
   - Compromise of long-term identity keys does not compromise past BLE session traffic.

2. **Authenticated Encryption:**
   - All GATT packets after handshake are encrypted using AES-GCM with 96-bit nonces.
   - Nonces combine session salt and a 32-bit strictly monotonic frame counter.
   - Replayed frames fail nonce uniqueness check and are discarded immediately.

3. **MITM Mitigation:**
   - BLE discovery leads into the connection ladder where TLS 1.3 certificate pinning or SAS out-of-band mutual confirmation takes place.
   - BLE link serves as a control plane bootstrapping transport, never bypassing end-to-end authentication.

---

## 2. Verdict

**APPROVED.** Cryptographically secure and resistant to passive and active wireless attacks.
