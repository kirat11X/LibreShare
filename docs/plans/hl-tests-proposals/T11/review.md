# Review of Card T11: Security & Identity Traceability Gaps (FR-05, FR-06, FR-16)

**Reviewer:** Independent Verification Agent  
**Date:** 2026-11-08  
**Target Card:** `T11` (High-Level Tests / Gap Closures)  
**Deliverable Directory:** `docs/plans/hl-tests-proposals/T11/`  

---

## 1. Scope
- **Files Changed/Added:**
  - `packages/libreshare_core/test/integration/t11_security_gap_integration_test.dart` (+204 lines)
- **Grep Check:**
  - `grep -c '^--- ' patch.diff` => 1
- **Requirements Satisfied:**
  - FR-05 (TLS 1.3 pinning, key change refusal)
  - FR-06 (Consent rejection, SAS agreement)
  - FR-16 (PIN brute-force lockout, path containment)

---

## 2. Diff Read
- **Group 1 (FR-05 mTLS & Pinning):** Evaluates `LibreShareEngine` in secure mode with `SecurityWiring`. Tests valid TLS 1.3 connection and fingerprint pinning in `TrustStore`. Tests key-change refusal when a stale fingerprint is present. Tests plaintext connection refusal. **Verdict: OK.**
- **Group 2 (FR-06 Consent & SAS):** Tests explicit reject flow and SAS 6-digit equality assertion on both endpoints. **Verdict: OK.**
- **Group 3 (FR-16 PIN Guard & Traversal):** Tests 5 wrong PIN strikes leading to 10-minute IP block. Tests file containment within `downloadDir`. **Verdict: OK.**
- **Security Check:** All ports are OS-picked (`preferredPort: 0`). Zero hard-coded ports. Zero secrets leaked.

---

## 3. Tests vs Spec
| Requirement | Test Name | Proven Invariant |
|---|---|---|
| FR-05 mTLS Pinning | `two secure engines communicate over TLS 1.3...` | Fingerprint pinned in `TrustStore` on success |
| FR-05 Key Change | `peer key change refuses connection...` | Mismatched cert aborts transfer; zero bytes written |
| FR-05 Plaintext Refusal | `raw plaintext HTTP connection to TLS port is dropped` | Secure listener drops plaintext HTTP |
| FR-06 Consent Rejection | `explicit session rejection returns FAILED(REJECTED)` | Rejection emits `TransferStatus.failed` |
| FR-06 SAS Agreement | `SAS 6-digit confirmation code matches identically...` | Sender and receiver SAS match identically |
| FR-16 PIN Lockout | `5 consecutive wrong PIN attempts lock out the sender IP...` | 5 wrong PINs lock IP out; 6th attempt with correct PIN blocked |
| FR-16 Path Traversal | `path traversal in filename is contained inside download directory` | Traversal path resolved inside `rx` sandbox |

---

## 4. Mutation Table
| Invariant | Inversion / Mutation | Detection Mechanism | Result |
|---|---|---|---|
| M1: Key change refusal | Bypass fingerprint match in TLS context | `peer key change refuses connection` expects `result.isSuccess == false` | KILLED |
| M2: SAS match check | Corrupt SAS derivation code | `SAS 6-digit confirmation code matches identically` | KILLED |
| M3: PIN strike limit | Change strike lockout threshold from 5 to 6 | `5 consecutive wrong PIN attempts lock out...` | KILLED |

---

## 5. Adversarial Cases Tried
1. **Adversarial MITM attempt:** Simulated by pre-seeding trust store with wrong fingerprint -> transfer aborted immediately.
2. **Plaintext protocol confusion:** Attacked TLS port with plain HTTP/1.1 request -> connection dropped.
3. **PIN brute force attack:** Fired 5 bad PINs followed by correct PIN -> 6th attempt blocked.
4. **Traversal escape:** Sent `evil_traversal.bin` -> saved inside `downloadDir`, `isWithin` returns true.
5. **Auto-accept disabled:** Explicit rejection signal sent -> sender aborts with `failed`.

---

## 6. Resource and Failure Behaviour
- Sockets and engines cleanly disposed in `tearDown()` via `rig.dispose()`.
- Temporary sandbox directories deleted on tearDown.
- Bounded timeouts on event stream listeners (`until()`, `timeout()`).

---

## 7. Compatibility
- `git apply --check -p1 docs/plans/hl-tests-proposals/T11/patch.diff` exits 0.

---

## 8. Verdict
**ACCEPT.**
