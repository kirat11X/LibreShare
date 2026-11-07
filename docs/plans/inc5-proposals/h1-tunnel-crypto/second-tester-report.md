# Module H1 Second Tester Report: tunnel_crypto

Date: 2026-11-06
Reviewer: Antigravity Adversarial Tester
Status: ACCEPTED

---

## 1. Adversarial Spec-Gap & Security Review

1. **Nonce Handling:**
   - Evaluated CSPRNG nonce generation (`Random.secure()` by default).
   - Nonces are 12 fresh bytes generated on every single seal invocation.
   - Nonces are never derived from predictable counters or static state.
   - Replay / repeat testing: confirmed no nonce collision across tests.

2. **AAD Canonical Byte Representation:**
   - ByteData big-endian serialization guarantees endianness independence across Little-Endian (x86_64, ARM64) and Big-Endian architectures.
   - AAD explicitly includes the message length (`u64be plaintextLen`) to prevent length extension / truncation ambiguity.

3. **Subkey Separation:**
   - HKDF derivation uses distinct domain strings (`sid`, `manifest`, `data`, `ack`, `sas`).
   - Cross-purpose attempts (e.g. attempting to open a chunk as an ack, or manifest as a chunk) fail cryptographically because they use completely distinct subkeys and different wire purpose bytes in the AAD.

4. **Information Leakage / Redaction:**
   - Neither exception messages nor `toString()` representations expose plaintext, keys, nonces, or tags.
   - `toString` on `TunnelKeys` returns strictly `'TunnelKeys(redacted)'`.
   - `TunnelCryptoException.toString()` returns strictly `'TunnelCryptoException(${error.name})'`.

**Verdict:** PASS.
