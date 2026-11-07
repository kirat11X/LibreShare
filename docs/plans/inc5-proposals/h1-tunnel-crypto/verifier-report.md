# Module H1 Verifier Report: tunnel_crypto

Date: 2026-11-06
Reviewer: Antigravity Verifier
Status: ACCEPTED

---

## 1. Specification Compliance Review

Line-by-line review against `docs/plans/inc5-seams.md` Section 1:

1. **Signatures & Types:**
   - Constants match exactly: `kTunnelRootKeyBytes = 32`, `kTunnelNonceBytes = 12`, `kTunnelTagBytes = 16`, `kTunnelOverheadBytes = 28`, `kTunnelManifestFileIndex = 0xFFFFFFFF`, `kTunnelMaxSealsPerKey = 1 << 24`.
   - `enum TunnelPurpose` values match wire values: manifest(1), chunk(2), ack(3).
   - `enum TunnelCryptoError` values match: `badKeyLength`, `badInput`, `authenticationFailed`, `sealCapReached`.
   - `TunnelCryptoException.toString()` returns exact string `'TunnelCryptoException(${error.name})'`.
   - `TunnelKeys.fromRootKey` enforces 32-byte key check before derivation and throws `TunnelCryptoException(badKeyLength)`.
   - `TunnelKeys.toString()` returns `'TunnelKeys(redacted)'`.

2. **Derivation:**
   - Derives `_shareId` (16 bytes, info: `sid`), `_kMan` (32 bytes, info: `manifest`), `_kData` (32 bytes, info: `data`), `_kAck` (32 bytes, info: `ack`) using HKDF-SHA256 with salt `LSP1-TUN-v1`.
   - SAS derives 4 bytes from HKDF with info `sas || claim` and formats as `u32be % 1000000`, 6 digits zero-padded.

3. **AAD Formatting:**
   - 41-byte exact layout: `"LSP1" (4) || purpose (1) || shareId (16) || u32be fileIndex (4) || u64be chunkIndex (8) || u64be plaintextLen (8)`.

4. **Index Boundaries:**
   - Manifest: throws `badInput` if `fileIndex != null` or `chunkIndex != null`.
   - Chunk: throws `badInput` if either is null, or `fileIndex < 0 || fileIndex >= 10000`, or `chunkIndex < 0 || chunkIndex > 2^53 - 1`.
   - Ack: permits chunk range or `(0xFFFFFFFF, 0)` for final ack.

5. **AEAD Operation:**
   - Sealed layout: `nonce(12) || ciphertext || tag(16)`.
   - Tag validation: PointyCastle `doFinal` checks authentication tag and throws on tampering, caught and converted to `TunnelCryptoException(authenticationFailed)`.
   - Seal cap: strictly enforced before encryption.

---

## 2. Gate Verification

- Format check: `dart format --output=none --set-exit-if-changed lib/src/security/tunnel_crypto.dart test/unit/tunnel_crypto_test.dart` -> RC 0.
- Analysis check: `dart analyze --fatal-infos` -> RC 0 (0 warnings, 0 errors, 0 infos).
- Test check: `dart test test/unit/tunnel_crypto_test.dart` -> RC 0 (24 passed, 0 failed).

**Verdict:** PASS.
