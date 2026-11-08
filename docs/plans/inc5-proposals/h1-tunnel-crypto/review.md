# Review: Card H1 (tunnel_crypto)

## 1. Scope
- Exact files changed/added:
  - `packages/libreshare_core/lib/src/security/tunnel_crypto.dart` (new file, `patch.diff` count: 1 file, `grep -c '^--- ' patch.diff` = 1)
  - `packages/libreshare_core/test/unit/tunnel_crypto_test.dart` (new test suite, 24 tests)
  - `packages/libreshare_core/test/conformance/fixtures/tunnel_crypto_vectors.json` (test vectors)
- Spec & plan rows satisfied:
  - `FR-14` (Internet Link Transfer via Tunnel with E2E AEAD confidentiality and integrity)
  - `NFR-04` (Security: AES-256-GCM, RFC 5869 HKDF-SHA256 key separation, 128-bit tag, 96-bit random nonce)
  - `docs/plans/inc5-seams.md` Section 1 (`TunnelKeys`, `TunnelPurpose`, `TunnelCryptoException`, `TunnelCryptoError`)

## 2. Diff Read
- `L1-43` (Constants, enums, exception class): OK. All wire values match `inc5-seams.md`. `TunnelCryptoException.toString()` redacts all internal state; exposes only `error.name`.
- `L45-89` (Class `TunnelKeys.fromRootKey` & HKDF derivation): OK. **[SECURITY-CRITICAL: Keys]** Derives `_shareId`, `_kMan`, `_kData`, `_kAck` with domain separation salt `LSP1-TUN-v1`. Enforces exact 32-byte root key length before proceeding.
- `L91-104` (`shareId` accessor & `_keyFor` dispatch): OK. Returns defensive copy of `_shareId`.
- `L106-136` (`_checkIndices` validation): OK. **[SECURITY-CRITICAL: Untrusted Input]** Rejects out-of-range chunk index (`> 2^53 - 1`), file index (`>= 10000`), or invalid combinations for manifest/chunk/ack.
- `L138-166` (`_buildAad` construction): OK. **[SECURITY-CRITICAL: AAD Binding]** 41-byte canonical big-endian representation: `"LSP1" || purpose || shareId (16) || fileIndex (u32be) || chunkIndex (u64be) || plaintextLen (u64be)`.
- `L168-215` (`_aesGcmSeal` & `_aesGcmOpen` AEAD engine): OK. **[SECURITY-CRITICAL: Crypto/Tag]** PointyCastle GCMBlockCipher(AESEngine), 128-bit tag. Decryption catches MAC failures and throws `TunnelCryptoError.authenticationFailed`.
- `L217-250` (`seal` & `open` methods): OK. **[SECURITY-CRITICAL: Nonce/Seal Cap]** Enforces $2^{24}$ seal count ceiling, generates 12-byte CSPRNG nonce (`Random.secure()`), validates overhead minimum length (28 bytes).
- `L251-271` (`sas` 6-digit code derivation): OK. **[SECURITY-CRITICAL: SAS]** HKDF-SHA256 with info `sas || claim`, modulo $10^6$, 6-digit zero-padded.
- `L272-291` (`sealWithNonce` test hook & `toString`): OK. **[SECURITY-CRITICAL: Leak Prevention]** `toString` returns strictly `'TunnelKeys(redacted)'`.

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Contract constants | `constants match contract` | Exact values for root key (32), nonce (12), tag (16), overhead (28), max seals ($2^{24}$). |
| Exception redaction | `TunnelCryptoException toString contains only error.name, never secrets` | Confirms no plaintext, key, nonce or path appears in exception string. |
| Key redaction | `TunnelKeys toString is redacted` | Confirms `toString()` equals `'TunnelKeys(redacted)'`. |
| Root key length guard | `rootKey must be exactly 32 bytes` | Throws `TunnelCryptoError.badKeyLength` on 31 and 33-byte inputs. |
| KAT vectors | `Known-answer vectors ...` (5 tests) | Bit-for-bit validation of HKDF keys, shareId, SAS, manifest, chunk, ack against independent Python reference vectors. |
| Input validation | `Index validation rules (badInput)` (6 tests) | Enforces strict bounds on `fileIndex`, `chunkIndex`, sealed byte length, and claim length. |
| Tamper resistance | `Tamper and Cross-Purpose Refusal` (4 tests) | Tampered ciphertext, bad key, mismatched purpose, or swapped indices immediately throw `authenticationFailed`. |
| Seal cap ceiling | `seal cap reached throws sealCapReached and stops further seals` | Throws `sealCapReached` at limit, preventing nonce exhaustion under single key. |
| Input immutability | `seal and open do not mutate inputs` | Verifies plaintext and ciphertext buffers are untouched by operation. |

All assertions contain active `expect` statements with exact matcher evaluation (zero empty tests, zero skips).

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| 32-byte key length check | Invert `rootKey.length != 32` | `rootKey must be exactly 32 bytes` | rc=1 | `diff -r` clean, rc=0 |
| Wire purpose byte | Set `purpose.wireValue = 99` | `manifest sealWithNonce matches python3 vector` | rc=1 | `diff -r` clean, rc=0 |
| AAD length prefix | Remove `plaintextLen` from AAD | `manifest sealWithNonce matches python3 vector` | rc=1 | `diff -r` clean, rc=0 |
| Authentication tag check | Swallow exception in `_aesGcmOpen` | `tampering any byte of sealed message throws authenticationFailed` | rc=1 | `diff -r` clean, rc=0 |
| Seal count cap | Disable `_sealCount >= maxSeals` | `seal cap reached throws sealCapReached` | rc=1 | `diff -r` clean, rc=0 |
| Overhead length check | Remove `sealed.length < 28` | `open with sealed.length < 28 throws badInput` | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **Truncated ciphertext (< 28 bytes):** Throws `TunnelCryptoError.badInput` immediately without executing AEAD open.
2. **Bit-flipped authentication tag (1 bit inverted in last 16 bytes):** Throws `TunnelCryptoError.authenticationFailed` in PointyCastle `doFinal`.
3. **Cross-purpose replay (sealing a manifest and attempting to open as a chunk):** Throws `TunnelCryptoError.authenticationFailed` due to subkey separation (`_kMan` vs `_kData`) and AAD purpose mismatch.
4. **Index spoofing (sealing chunk 0 of file 1, attempting to open as chunk 1 of file 1):** Throws `TunnelCryptoError.authenticationFailed` due to AAD binding.
5. **Zero-length plaintext:** Seals to 28-byte packet (12-byte nonce + 16-byte tag), opens cleanly to empty `Uint8List`.

## 6. Resource and Failure Behaviour
- Pure in-memory cryptographic functions: no file handles, sockets, timers, or background isolates are retained.
- Memory: buffers are fixed-size or allocated proportionally to input length; no unbounded queues.
- Secret redaction: `toString` on `TunnelKeys` returns `'TunnelKeys(redacted)'`. `TunnelCryptoException.toString()` prints only `'TunnelCryptoException(error.name)'`. Zero keys, plaintext, or nonces are exposed in exceptions.

## 7. Compatibility
- `patch -p1 --dry-run < docs/plans/inc5-proposals/h1-tunnel-crypto/patch.diff`:
  `rc=0` (clean application against current repository tree).
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/security/tunnel_crypto.dart`:
  `rc=0` (0 errors, 0 warnings, 0 infos).
- `dart format --output=none --set-exit-if-changed packages/libreshare_core/lib/src/security/tunnel_crypto.dart packages/libreshare_core/test/unit/tunnel_crypto_test.dart`:
  `rc=0` (0 files changed).
- Existing test suite regression check: all existing core unit tests pass without conflicts.

## 8. Verdict
**ACCEPT**
What the final deep review must re-check:
- HKDF salt literal `'LSP1-TUN-v1'` and info literals (`'sid'`, `'manifest'`, `'data'`, `'ack'`, `'sas'`) against LSP-1 spec Section 4.5.
- PointyCastle GCMBlockCipher initialization: verify 128-bit MAC tag size and non-reuse of nonces across distinct seals.
