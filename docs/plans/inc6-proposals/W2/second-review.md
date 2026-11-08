# Second Review: Card W2 (`bip340.dart`, `nip01.dart`, `nostr_backend.dart`)

**Reviewer:** Antigravity Adversarial Security Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc6-proposals/W2/`  
**Verdict:** PASS (No security-blocking findings)

---

## 1. Threat Model & Attacker Capabilities
- **Untrusted Actor:** Malicious Nostr relay operator, network man-in-the-middle, or Byzantine relay node.
- **Attacker Capabilities:**
  1. Forge Nostr events or forge BIP-340 Schnorr signatures.
  2. Substitute pubkeys or alter event fields (`created_at`, `kind`, `tags`, `content`).
  3. Send malformed frames (e.g. huge frames > 128 KiB) to exhaust receiver memory.
  4. Abruptly close connections or inject connection resets.
- **Security Goals:**
  1. **Signature Non-forgeability:** Only holders of the secret key can generate valid BIP-340 signatures.
  2. **Event Immutability:** Any tampering with event tags, timestamps, or content invalidates both the event ID and the BIP-340 signature.
  3. **Relay Independence:** The client never trusts a single relay; compromised or offline relays cannot prevent communication if another relay is available.

---

## 2. Attack Attempts & Verification

### Attack 1: Nonce Bias / Flawed Nonce Generation in BIP-340
- **Vector:** In Schnorr signatures, reusing nonces $r$ across two signatures under the same private key allows an attacker to compute the private key: $sk = (s_1 - s_2) / (e_1 - e_2)$.
- **Result:**
  `bip340.dart` strictly adheres to deterministic nonce derivation (RFC 6979 / BIP-340):
  $$d' = \text{tagged\_hash}("BIP0340/nonce", sk \parallel a \parallel m)$$
  where $a$ is 32 bytes of fresh auxiliary cryptographically secure randomness (`secureRandomBytes(32)`).
  This eliminates duplicate nonces even under identical messages while preventing deterministic side-channel leakage.
- **Finding:** SAFE.

### Attack 2: Public Key Malleability / Sign Bit Attack
- **Vector:** BIP-340 uses 32-byte x-only public keys where the y-coordinate is implicit (must be even). An attacker supplies a point with odd y-coordinate or out-of-bounds coordinates.
- **Result:**
  `getBip340PublicKey()` verifies that the y-coordinate is even; if odd, it negates the secret key ($n - sk$) prior to serialization, guaranteeing canonical x-only representation. On verification, `_liftX()` explicitly checks that the lifted curve point satisfies $y^2 \equiv x^3 + 7 \pmod p$ and that $y$ is even ($y \pmod 2 == 0$).
- **Finding:** SAFE.

### Attack 3: Event Injection with Altered Expiration or Channel Tag
- **Vector:** Attacker modifies the `["p", channelId]` tag or `["expiration", ttl]` tag on an event in transit.
- **Result:**
  In NIP-01, the event ID is defined as $H = \text{SHA256}(\text{canonical\_json}([0, pubkey, created\_at, kind, tags, content]))$. Altering any tag changes the canonical JSON, causing $H \neq \text{event.id}$. If the attacker recalculates $H$, the BIP-340 signature $\text{sig}$ (which signs $H$) becomes invalid. The client drops the event immediately.
- **Finding:** SAFE.

### Attack 4: Denial of Service via Oversized Relay Frames
- **Vector:** Hostile relay transmits continuous frames > 128 KiB or infinite JSON strings.
- **Result:**
  `NostrBackend` configures a hard frame size limit (max 131,072 bytes) and drops any frames exceeding the threshold before JSON deserialization.
- **Finding:** SAFE.

---

## 3. Residual Risk / Final Deep Review Notes
- Ensure that auxiliary randomness parameter $a$ passed to `signBip340` is always sourced from `secureRandomBytes(32)` in production.
