# Second Review: Card J3 (LinkShare & ShareStore: Claim Binding Security)

## 1. Diff-Only Threat Model
Starting strictly from `packages/libreshare_core/lib/src/share/link_share.dart` and `share_store.dart` diffs:
- **Attacker Capabilities:**
  - Mallory intercepts or observes a public link to a one-time file share.
  - Mallory attempts to race the legitimate recipient ("Bob") to claim the share or hijack Bob's session.
  - Mallory attempts to re-download files after Bob has finished.
  - Mallory inspects local disk storage on sender's device to recover root encryption keys.
- **Protected Assets:**
  - One-time share exclusivity (only the legitimate intended recipient may complete the download).
  - Post-transfer confidentiality (links cannot be reused after completion).
  - Root key $k$ (never stored on non-volatile media).
- **Entry Points:**
  - `LinkShare.bindClaim(claim)`
  - `LinkShare.complete(ack)`
  - `ShareStore.saveShare(record)`

## 2. Adversarial Break Attempts & Results
1. **Threat: Share Hijacking via Concurrent Claim (Mode 1 Race)**
   - *Attempt:* Send two simultaneous requests with different `X-LS-Claim` identifiers to bind to a Mode 1 one-time link.
   - *Result:* Blocked. The first claim atomically binds to `_boundClaim`. Any subsequent claim with a differing identifier is rejected with `ClaimConflictException` (mapped to HTTP 409 Conflict), preventing session hijacking.
2. **Threat: Link Reuse Post-Download**
   - *Attempt:* Re-request chunks after the legitimate recipient sends a sealed final ACK.
   - *Result:* Blocked. Verified receipt of the final ACK transitions `LinkShare` to `ShareState.completed`. Any subsequent request returns HTTP 410 Gone.
3. **Threat: Forensic Key Recovery from Storage Media**
   - *Attempt:* Read raw JSON files from `ShareStore` directory on disk to extract AES-256 root key $k$.
   - *Result:* Blocked. Root key $k$ is kept strictly in volatile memory of the active sender isolate. `ShareRecord.toJson()` serializes only `shareId`, `token`, `maxReceivers`, timestamps, and filenames. Zero cryptographic key material is written to disk.
4. **Threat: Byte Budget Evasion / Amplification Attack**
   - *Attempt:* Request chunk ranges repeatedly without triggering completion ACK.
   - *Result:* Blocked. `recordBytesSent` tracks aggregate egress bandwidth against the $2 \times \text{size} \times \text{receivers}$ ceiling. Once exceeded, state transitions to `revoked`, cutting off the attacker.

## 3. Findings & Verdict
- Findings: ZERO high/medium security vulnerabilities. Claim binding is strictly enforced, replay is prevented, and no root keys reach persistent storage.
- **Verdict:** ACCEPT (Security Verified).
