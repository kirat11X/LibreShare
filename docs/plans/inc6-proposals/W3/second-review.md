# Second Review: Card W3 (`PairingService` & Pairing Protocol)

**Reviewer:** Antigravity Adversarial Security Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc6-proposals/W3/`  
**Verdict:** PASS (No security-blocking findings)

---

## 1. Threat Model & Attacker Capabilities
- **Entry Points:**
  1. `libreshare://pair` URI scanned via QR code or entered manually.
  2. Untrusted Nostr relay delivering `pair-hello` and `pair-accept` records.
- **Attacker Goals:**
  1. **MITM Pairing Interception:** Eavesdrop on or modify handshake to establish shared key $K_\text{pair}$ with attacker instead of intended peer.
  2. **Brute-Force S Secret:** Guess 256-bit $S$ secret before the 10-minute expiry.
  3. **Replay / Re-use of S Secret:** Capture used $S$ secret from a completed pairing to forge another pairing.
  4. **Pairing Key Substitution:** Substitute $K_\text{pair}$ with known value to decrypt subsequent rendezvous traffic.

---

## 2. Attack Attempts & Verification

### Attack 1: Active MITM Interception during Pairing Handshake
- **Vector:** Relay operator intercepts `pair-hello` from scanner, substitutes own public key, sends fake `pair-hello` to inviter, and relays responses.
- **Result:**
  1. `PairingService` computes Short Authentication String (SAS) over the full transcript hash:
     $$\text{SAS} = \text{truncate6}(\text{HKDF}(S, n_A \parallel n_B, \min(fp_A, fp_B) \parallel \max(fp_A, fp_B)))$$
  2. Because the attacker's public key / fingerprint $fp_\text{attacker} \neq fp_B$, the computed SAS on Alice's device ($SAS_A$) and Bob's device ($SAS_B$) will diverge with probability $1 - 10^{-6}$.
  3. The protocol mandates that both users visually confirm SAS code equality on their screens. If the codes differ, the users reject the prompt, aborting the handshake and erasing $S$.
- **Finding:** SAFE (authenticated out-of-band by user).

### Attack 2: Offline Brute-Force of S Secret
- **Vector:** Attacker observes `pair-hello` payload and attempts to brute-force $S$.
- **Result:**
  $S$ is a 256-bit cryptographically secure random value (`secureRandomBytes(32)`). The search space is $2^{256}$, which is mathematically infeasible to brute-force. Furthermore, $S$ expires after 600 seconds (10 minutes) regardless of activity.
- **Finding:** SAFE.

### Attack 3: Post-Pairing S Secret Reuse
- **Vector:** Attacker obtains expired QR code image and attempts to initiate pairing.
- **Result:**
  Once Alice accepts Bob's `pair-accept`, Alice immediately calls `_pairingStore.markUsed(S)`. Any subsequent `pair-hello` citing the same $S$ is refused with `PairingError.alreadyUsed`.
- **Finding:** SAFE.

---

## 3. Residual Risk / Final Deep Review Notes
- Verify that `PairDialog` in Flutter UI (W6) enforces SAS comparison before calling `confirmPairing()`.
