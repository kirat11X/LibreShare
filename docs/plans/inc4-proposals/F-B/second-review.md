# Second Review: Card F-B (D6 Candidate Pinning Security)

## 1. Diff-Only Threat Model
Starting strictly from `packages/libreshare_core/lib/src/engine/libreshare_engine.dart` and `file_sender.dart` diffs:
- **Attacker Capabilities:**
  - Mallory operates a rogue access point or rogue IP address listed as a secondary ladder candidate (tier 2 or tier 3).
  - Mallory monitors local network traffic and actively severs tier 1 (e.g. deauth frame or TCP reset) to force the client to fall back to Mallory's interface.
  - Mallory presents a self-signed or CA-signed certificate for an arbitrary identity key.
- **Protected Assets:**
  - Session secrets, pairwise PIN digits, SAS codes.
  - Plaintext file contents and metadata.
  - Integrity of candidate ladder fallback.
- **Entry Points:**
  - `_findEndpointWithLadder(candidates, pin)`
  - `_tierClient(candidate, pin)`
  - `FileSender.nextClient` callback

## 2. Adversarial Break Attempts & Results
1. **Threat: Impostor Ladder Candidate Takeover**
   - *Attempt:* Place Mallory on tier 2 candidate with an altered TLS certificate. Cut tier 1 mid-transfer to force client to connect to Mallory.
   - *Result:* Blocked. In `_tierClient`, the presented certificate fingerprint is compared against `pin` before any application request or PIN is dispatched. The fingerprint mismatch throws `EndpointRefusedException` / `PeerFingerprintMismatchException` and emits `PeerKeyChanged`.
2. **Threat: Plaintext or PIN Leakage to Mallory**
   - *Attempt:* Observe HTTP traffic arriving at Mallory's rogue server during fallback probe.
   - *Result:* Blocked. Verified by `ladder_pin_test.dart`: Mallory receives exactly 0 bytes of file payload, 0 bytes of manifest, and 0 PIN digits.
3. **Threat: Mid-Transfer Fallback Keystream / State Corruption**
   - *Attempt:* Mallory attempts to replay chunk 0 or induce re-upload of completed chunks.
   - *Result:* Blocked. The sender queries `GET /state` upon switching to a valid candidate and skips all chunks already recorded in `_receivedSet`. No acknowledged chunk is transmitted a second time.
4. **Threat: Exhaustion / Infinite Fallback Spin**
   - *Attempt:* Provide an endless list of failing or hostile candidates.
   - *Result:* Blocked. Each candidate is attempted with bounded connection timeouts. If all ladder candidates fail or are refused, the transfer terminates cleanly with `FailureReason.noConnection`.

## 3. Findings & Verdict
- Findings: ZERO high/medium security vulnerabilities. Candidate identity pinning is strictly enforced on all tiers; rogue candidates cannot intercept mid-transfer fallbacks or harvest PINs.
- **Verdict:** ACCEPT (Security Verified).
