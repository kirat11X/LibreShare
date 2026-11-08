# Second Review: Card H1 (tunnel_crypto)

## 1. Diff-Only Threat Model
Starting strictly from `packages/libreshare_core/lib/src/security/tunnel_crypto.dart` diff:
- **Attacker Capabilities:**
  - Mallory is an untrusted tunnel relay (Cloudflare Quick Tunnel / zrok origin proxy).
  - Mallory observes all encrypted bytes, can drop, duplicate, truncate, reorder, delay, or tamper with any ciphertext packet.
  - Mallory can submit forged claims, forged manifest packets, or altered chunk index tags.
- **Protected Assets:**
  - Root encryption key, derived HKDF subkeys (`_kMan`, `_kData`, `_kAck`), SAS confirmation codes.
  - Plaintext file contents, filenames, and transfer metadata.
- **Entry Points:**
  - `TunnelKeys.fromRootKey(rootKey)`
  - `open(purpose, sealed, {fileIndex, chunkIndex})`
  - `sas(claim)`

## 2. Adversarial Break Attempts & Results
1. **Threat: Nonce Collision under Extended Use**
   - *Attempt:* Exhaust nonces by calling `seal` repeatedly past the birthday bound.
   - *Result:* Blocked. Line 224 enforces `_sealCount >= maxSeals` ($2^{24}$ limit) and throws `TunnelCryptoException(sealCapReached)`, preventing keystream exhaustion on any single session key.
2. **Threat: Cross-Purpose Replay (Manifest $\leftrightarrow$ Chunk $\leftrightarrow$ Ack)**
   - *Attempt:* Take a valid sealed manifest ciphertext and attempt to open it as chunk index 0, or take a valid ack ciphertext and open as manifest.
   - *Result:* Blocked. Key separation (HKDF info tags `'manifest'`, `'data'`, `'ack'`) ensures distinct 256-bit symmetric keys. Furthermore, AAD wire value `purpose.wireValue` (1, 2, or 3) is bound to the MAC tag.
3. **Threat: Chunk Reordering / Splicing Across Files**
   - *Attempt:* Swap chunk 0 from file 0 into chunk 0 of file 1 in a multi-file transfer.
   - *Result:* Blocked. AAD explicitly includes `fileIndex` (u32be) and `chunkIndex` (u64be). MAC verification in PointyCastle fails and throws `TunnelCryptoException(authenticationFailed)`.
4. **Threat: Length Extension / Truncation Ambiguity**
   - *Attempt:* Truncate ciphertext or prepend/append zero-bytes to plaintext prior to tag verification.
   - *Result:* Blocked. AAD binds `plaintextLen` (u64be) directly, and AES-GCM calculates authentication tag over both ciphertext and AAD. Any alteration fails authentication.
5. **Threat: Information Leakage in Diagnostic Traces**
   - *Attempt:* Inspect `toString()` output and exception trace outputs when invalid inputs are fed.
   - *Result:* Blocked. `TunnelKeys.toString()` outputs literal `'TunnelKeys(redacted)'`. `TunnelCryptoException.toString()` outputs strictly `'TunnelCryptoException(${error.name})'`. No key material or plaintext bytes are recoverable.

## 3. Findings & Verdict
- Findings: ZERO high/medium security vulnerabilities. No secret leak, no check bypass, no memory corruption.
- **Verdict:** ACCEPT (Security Verified).
