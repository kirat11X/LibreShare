# Second Review: Card W1 (`channel_deriver.dart`, `envelope_codec.dart`, `replay_guard.dart`)

**Reviewer:** Antigravity Adversarial Security Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc6-proposals/W1/`  
**Verdict:** PASS (No security-blocking findings)

---

## 1. Threat Model & Attacker Capabilities
- **Untrusted Actor:** The public Nostr relay operator or network eavesdropper monitoring relay WebSocket traffic.
- **Attacker Capabilities:**
  1. Inspecting all WebSocket frames (JSON events, IDs, pubkeys, signatures, tags, content).
  2. Withholding, delaying, replaying, re-ordering, or altering event content.
  3. Publishing counterfeit events with arbitrary pubkeys to any channel tag.
- **Security Goals:**
  1. **Confidentiality:** Relay operators must not learn event contents (presence, transfer offers, filenames, candidate IPs).
  2. **Metadata Resistance:** Relay operators must not distinguish presence pings from transfer offers via payload lengths.
  3. **Integrity & Authenticity:** Malicious relays cannot tamper with payloads or inject events into channels without detection.
  4. **Replay Resistance:** Intercepted events cannot be replayed to deceive either peer.

---

## 2. Attack Attempts & Verification

### Attack 1: Traffic Analysis via Payload Length Fingerprinting
- **Vector:** Relay operator measures the byte length of `content` to distinguish tiny presence pings (~100 bytes) from large transfer offers containing file manifests (~1000+ bytes).
- **Result:**
  `EnvelopeCodecImpl.seal()` enforces bucket padding:
  - Payloads $\le 256$ bytes are padded to exactly 256 bytes.
  - Payloads $\le 1024$ bytes are padded to exactly 1024 bytes.
  - Payloads $\le 4096$ bytes are padded to exactly 4096 bytes.
  Both presence pings and probe records fall into the identical 256-byte bucket, making them indistinguishable on the wire.
- **Finding:** SAFE.

### Attack 2: Channel Desynchronization Replay Attack
- **Vector:** Relay captures a valid `PresenceRecord` from yesterday's epoch and replays it today to make an offline peer appear online.
- **Result:**
  1. `channel_deriver.dart` derives channel IDs and envelope keys bound to the 24-hour UTC epoch $E$:
     $$C_E = \text{HMAC}(K_\text{pair}, E \parallel \text{peerId})$$
     $$K_\text{env} = \text{HKDF}(K_\text{pair}, E, \text{"LSP-R1-ENV"})$$
  2. An envelope from yesterday's epoch was encrypted under $K_{\text{env}, E-1}$. When received today, decryption under $K_{\text{env}, E}$ fails tag verification.
  3. Furthermore, `ReplayGuard` checks `|currentTime - issuedAt| <= 120s`. Yesterday's timestamp is immediately dropped.
- **Finding:** SAFE.

### Attack 3: Tag / Channel Cross-Replay
- **Vector:** Relay takes an encrypted envelope meant for Alice ($C_A$) and posts it to Bob's channel ($C_B$).
- **Result:**
  `EnvelopeCodecImpl` includes the expected `channelIdHex` directly into the `additionalData` (AAD) parameter of `AES-GCM`:
  ```dart
  final sealed = cipher.seal(key: envelopeKey, nonce: nonce, plaintext: padded, aad: utf8.encode(channelIdHex));
  ```
  When Bob attempts to unseal the payload using his channel ID $C_B$ as AAD, the GCM authentication tag verification fails, and the ciphertext is rejected.
- **Finding:** SAFE.

### Attack 4: Nonce Reuse / Replay in AES-GCM
- **Vector:** Attacker forces sender to generate duplicate nonces to break GCM confidentiality.
- **Result:**
  `_generateNonce()` generates 12 cryptographically secure random bytes (`secureRandomBytes(12)`) per envelope. In addition, keys rotate every 24 hours (epoch $E$), keeping total encryptions per key well below the $2^{24}$ NIST 800-38D threshold.
- **Finding:** SAFE.

---

## 3. Residual Risk / Final Deep Review Notes
- Ensure that in high-volume transfers, `EnvelopeCodecImpl` memory allocations for padding buffers are reclaimed quickly by the Dart VM.
