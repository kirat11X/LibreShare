# Card T11 Delivery Report: Security & Identity Traceability Gaps (FR-05, FR-06, FR-16)

**Date:** 2026-11-08  
**Author:** Gemini (LibreShare Project Lead)  
**Deliverable:** `docs/plans/hl-tests-proposals/T11/`  
**Status:** READY  

---

## 1. Overview & Traceability Target
Card T11 addresses the core security-flavoured traceability gaps identified during the T1 audit (`traceability-gaps.md`), targeting:
1. **FR-05 (Mutual TLS 1.3 & Certificate Pinning):**
   - Verified that two secure engines communicate over TLS 1.3 and pin peer public key fingerprints in their trust stores.
   - Verified that an unexpected peer key change refuses the connection immediately (`SessionFinished` with failure) and transfers zero bytes.
   - Verified that a raw plaintext HTTP connection to a secure listener port is dropped.
2. **FR-06 (Consent, Rejection, and SAS Agreement):**
   - Verified that an incoming session explicit rejection returns `FAILED(REJECTED)`.
   - Verified that `SasReady` events are emitted on both peers with identical 6-digit codes prior to transfer completion.
3. **FR-16 (Security Controls: PIN Lockout & Traversal Containment):**
   - Verified that 5 consecutive wrong PIN attempts lock out the sender IP for 10 minutes, blocking subsequent connection attempts even if the correct PIN is provided.
   - Verified that path traversal filenames (`../../evil_traversal.bin`) are strictly contained inside the recipient's download folder.

---

## 2. Test File
- `packages/libreshare_core/test/integration/t11_security_gap_integration_test.dart` (7 tests covering FR-05, FR-06, FR-16).
- All nodes utilize OS-picked ephemeral ports (`preferredPort: 0` via `P6aRig`).

---

## 3. Patch Verification
```bash
git apply --check -p1 docs/plans/hl-tests-proposals/T11/patch.diff
rc=0
```
