# Card A2 Report: Increment 7 Wave A2 Secure Channel & BleSession State Machine

**Card:** A2 (Increment 7 Wave A2: Secure Channel & BleSession State Machine)  
**Author:** Lead / Orchestrator  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 10/10 tests pass x3, 4/4 mutations killed)

---

## 1. Summary of Changes
Card A2 implements the cryptographic handshake, authenticated key exchange, and secure channel state machine for LS-BLE/1 control communication over GATT:

1. **`ble_crypto.dart`**:
   - `BleEphemeralKeyPair`: Generates ephemeral P-256 (prime256v1) key pairs; calculates 32-byte shared secrets via ECDH; redacting `toString()` prevents leaking private key material.
   - `generateBleNonce`: Generates cryptographically secure 16-byte base64 nonces ($n_c$, $n_p$).
   - `computeTranscriptHash`: Computes SHA-256 transcript hash $th = \text{SHA256}(\text{"LSBLE1"} \parallel M1 \parallel M2)$.
   - `deriveChannelKeys`: Derives directional 32-byte keys $k_{C2P}$ and $k_{P2C}$ using HKDF-SHA256 with salt=$th$ and info=`"LSBLE1-keys"`.
   - `BleAeadCipher`: Directional AES-256-GCM cipher with 12-byte nonces (4-byte direction || 8-byte monotonic counter), AAD=$th$. Rejects non-monotonic counters (replay protection) and modified authentication tags; redacting `toString()` prevents secret leakage.

2. **`ble_session.dart`**:
   - State machine: `idle` -> `handshaking` -> `authenticated` -> `offered` -> `agreed` -> `closed`.
   - Full M1/M2/AUTH mutual authentication exchange:
     - Central emits M1, peripheral replies M2.
     - ECDH shared secret and transcript hash $th$ computed.
     - Each peer signs $th$ using its persistent identity certificate under domain `LSBLE1-AUTH-C` / `LSBLE1-AUTH-P`.
     - Signatures verified via ECDSA with P-256 and SHA-256; certificate fingerprints checked against expected pinning if provided.
     - SAS code calculated identically by both peers using `security/sas.dart`.
     - Application messaging (`BleOffer`, `BleDecision`, `BleNetPlan`, `BleHotspot`, `BleJoined`) transmitted encrypted with frame fragmentation and reassembly.
     - Unified error handling wraps transport and crypto failures into `BleSecurityException` and terminates GATT sessions cleanly.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze` clean (0 issues).
- **Code Formatting**: `dart format` clean across all files.
- **Flake Gate**: 10/10 tests in `packages/libreshare_core/test/unit/ble/a2_ble_session_test.dart` passed across 3 consecutive cycles.
- **Mutation Sweep (4/4 killed)**:
  - **M1 (Replay check removal in `BleAeadCipher.open`)**: Replay test fails -> **KILLED** (`M1_KILLED`).
  - **M2 (Signature verification bypass in `BleSession`)**: Tampered AUTH signature test fails -> **KILLED** (`M2_KILLED`).
  - **M3 (Fingerprint verification bypass in `BleSession`)**: Fingerprint mismatch test fails -> **KILLED** (`M3_KILLED`).
  - **M4 (Corrupt Central SAS computation)**: SAS equality test fails -> **KILLED** (`M4_KILLED`).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for `ble_crypto.dart`, `ble_session.dart`, and `ble_contracts.dart`.
- `test/a2_ble_session_test.dart`: Unit and security test suite.
- `apply-notes.md`: Instructions for orchestrator application.
- `verifier-report.md`: Independent verifier sign-off.
- `second-tester-report.md`: Independent second security tester sign-off.
