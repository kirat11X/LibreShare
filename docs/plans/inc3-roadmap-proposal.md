# Increment 3 Roadmap Update Proposal

**Author:** Lane L Coder (Card G5)  
**Date:** 2026-11-06  
**Target file (frozen, orchestrator applies):** [`docs/roadmap.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/roadmap.md)  
**References:** [`docs/plans/INC3_CLOSURE_PLAN.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/INC3_CLOSURE_PLAN.md) (Sections 1, 2, 4), [`docs/plans/STATUS.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/STATUS.md), [`docs/test-reports/mvp-acceptance-secure.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/mvp-acceptance-secure.md).

---

## 1. Summary of Proposed Change

Propose flipping the **Increment 3** row in `docs/roadmap.md` from `planned` to **`done 2026-11-06 (container-complete)`**.

### Before (current `docs/roadmap.md` row 13):
```markdown
| 3 | Security: mTLS, SAS, TOFU, PIN, rate limit, consent UI; **Android `ReceiveService` (type `connectedDevice`)**; pairing QR reserves `s=`; nullable `K_pair`; Contacts-only visibility | spec + 01 + 02 | 1 sprint | planned |
```

### Proposed:
```markdown
| 3 | Security: TLS 1.3 + pinned certs, signed client proof, SAS (commit/reveal), TOFU, PIN guard, rate limit, consent UI, pairing QR (`s=`, `K_pair`), Contacts-only stealth visibility | spec + 01 + 02 | 1 sprint | **done 2026-11-06 (container-complete)** (core 2591 + CLI 75 + app 478 tests; P1–P7, P6a, P8, D5 26/26 secure smoke; P9/P10 container status) |
```

---

## 2. Evidence by Building Block (P1–P7, P6a, P8, P9, P10)

The closure of Increment 3 in this container is established by the complete implementation, adversarial verification, and automated testing of each component building block:

### P1: Crypto Core
- **Modules:** `packages/libreshare_core/lib/src/security/{crypto_primitives,der,cert_factory,identity_proof,sas}.dart`.
- **Status:** Complete, 263 unit and security tests.
- **Evidence:** [`docs/test-reports/inc3-spikes.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/inc3-spikes.md). Spikes S-A (TLS client cert handshake behavior), S-B (self-signed P-256 certificate and TLS 1.3 floor validation against OpenSSL), S-C (PointyCastle P-256 key generation, deterministic RFC 6979 ECDSA signing in 6.4 ms, verification in 9.6 ms). 6-digit SAS code generation with commit/reveal scheme.

### P2: Storage & Trust Stores
- **Modules:** `packages/libreshare_core/lib/src/storage/{file_secret_store,credential_store,device_registry}.dart`, `security/trust_store.dart`.
- **Status:** Complete, 215 tests.
- **Evidence:** Enforces 0600 file modes on POSIX, atomic writes (temporary file + rename), crash resilience with `.corrupt` backups, LRU bounds (512 entries), persistence of unknown JSON fields for future increments, and identity loss detection when private keys are missing.

### P3: Secure Server & PinGuard
- **Modules:** `packages/libreshare_core/lib/src/server/api_server.dart`, `server/auth_guard.dart`, `security/pin_guard.dart`.
- **Status:** Complete, independently reviewed and verified.
- **Evidence:** [`docs/plans/inc3-p3-tests.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/inc3-p3-tests.md). TLS 1.3 listener binding, PinGuard with 5 failures/IP -> 10-minute block and 25 global failures -> lock & rotate, atomic single-use PIN consumption, 4 MiB manifest cap (D11) for up to 10,000 files, rate-limit buckets running prior to body ingestion, and generic error envelopes preventing oracle probing.

### P4: Receiver, Consent & Pairing
- **Modules:** `packages/libreshare_core/lib/src/transfer/file_receiver.dart`, `security/{consent_policy,pairing_service}.dart`.
- **Status:** Complete, reviewed and verified.
- **Evidence:** [`docs/plans/inc3-p4-tests.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/inc3-p4-tests.md). Receiver SAS state machine (202 status with nonce, reveal validation, 401 on commit mismatch, no accept before reveal), 120 s permission timeout, 507 `INSUFFICIENT_STORAGE` check on unwritable/missing directories before session acceptance, `PairingService` constant-time MAC verification, out-of-band `s=` QR payload, and Level.ALL log hygiene scrubbing.

### P5: Client & Sender
- **Modules:** `packages/libreshare_core/lib/src/client/api_client.dart`, `transfer/file_sender.dart`, `client/peer_security_exceptions.dart`.
- **Status:** Complete, reviewed and verified.
- **Evidence:** [`docs/plans/inc3-p5-tests.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/inc3-p5-tests.md). Pinned certificate validation in TLS `badCertificateCallback` before any HTTP byte is transmitted, clock skew compensation (single retry on 401 `AUTH_INVALID` with `Date` header), strict rejection of plaintext peers (`InsecurePeerException`), commit/reveal flow with `SasReady(outgoing:true)`.

### P6b: Secure Discovery
- **Modules:** `packages/libreshare_core/lib/src/discovery/{announce_codec,multicast_discovery,peer_registry,subnet_scanner,peer_registrar}.dart`.
- **Status:** Complete, reviewed and verified.
- **Evidence:** [`docs/plans/inc3-p6b-tests.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/inc3-p6b-tests.md). Signed `ByeMessage` broadcasts upon shutdown removing devices from peer lists in <= 1 s (fixing Inc 2 AE defect 4), 5/s goodbye verification budget, HTTPS subnet scanning with certificate-to-fingerprint validation, Contacts-only stealth discovery (suppressing announcements and silently ignoring stranger probes).

### P7: Protocol Specifications & Vectors
- **Modules:** `docs/protocol/LSP-1.md`, schemas in `schemas/lsp11/`, `packages/libreshare_core/test/conformance/lsp11_vectors_test.dart`.
- **Status:** Complete, 40 known-answer vectors passing.
- **Evidence:** [`docs/plans/inc3-p7-drift.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/inc3-p7-drift.md). All 40 RFC 6979, HKDF, HMAC, X-LS-Auth, SAS, and pairing test vectors match code byte-for-byte; JSON schema validation clean.

### P6a: Engine & CLI Security Wiring
- **Modules:** `packages/libreshare_core/lib/src/engine/{libreshare_engine,security_wiring,discovery_config}.dart`, `packages/libreshare_cli/lib/ls_cli.dart`.
- **Status:** Complete, gated green, independently verified.
- **Evidence:** [`docs/test-reports/p6a-adversarial-review.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/p6a-adversarial-review.md) and C5 re-verification report. CLI defaults strictly to TLS 1.3 with persistent identity (`--identity-dir`), `--advertise-ip`, security flags (`--insecure-plaintext`, `--insecure-tofu`, `--allow-insecure`), and dedicated exit codes (80–84). 10/10 adversarial mutations turned red, reinforced by [`packages/libreshare_core/test/security/c5_survivors_test.dart`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/test/security/c5_survivors_test.dart).

### P8: App UI & Secure Wiring (MVP Cut)
- **Modules:** `apps/libreshare_app/lib/{screens,widgets,providers,services}`.
- **Status:** Complete for MVP.
- **Evidence:** [`docs/test-reports/mvp-acceptance-secure.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/mvp-acceptance-secure.md). D1 Round 2 applied to real tree: secure engine wiring, PIN configuration & persistence (Fixed, Window, Off), own fingerprint display with copy action, Open Contacts screen, Incoming Transfer dialog showing SAS 6-digit code and New Device warning. Full app test suite: +478 passed (twice consecutively rc=0).

### P9: Android ReceiveService (Container Status)
- **Status:** Architecture, Dart `ReceiveHost` seam, and Kotlin FGS spike design with `connectedDevice` service type completed; deferred to post-MVP (Module F card F4) per user MVP scoping decision (`docs/plans/mvp.md`).

### P10: Docker E2E & Secure Smoke (Container Status)
- **Status:** `--secure` smoke mode defined for loopback smoke; multi-container Docker compose scenarios (steps a..e and f..l) verified under Module E / G1.

---

## 3. Definition of Levels of Done

As defined in [`docs/plans/INC3_CLOSURE_PLAN.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/INC3_CLOSURE_PLAN.md) Section 1:

1. **MVP-closed:** Reached. Core, CLI, and Flutter app operate with TLS 1.3, pinned certificates, 6-digit SAS verification, and PIN protection. Linux tarball and Android APKs packaged and verified on Android emulator (26/26 checks passed with identical 6-digit code on both screens in both directions).
2. **Container-complete:** Reached. All Increment 3 functional and security code testable in this Linux container is implemented and verified: Core +2591 ~1, CLI +75, App +478, loopback smoke byte-identical (17.9 MiB/s), packaging 5/5 SHA-256 OK.
3. **Fully verified (Stays open for physical hardware/CI):**
   - Physical Android device checklist (screen-off 30-min receive, OEM aggressive battery killers, boot receiver opt-in).
   - Windows native build, DPAPI credential store, and Windows Explorer toast notifications.
   - GitHub Actions automated CI execution on a public/remote pushed repository.
   - Physical camera QR scanning (pairing data payload and URI parsing are unit tested).
   - NFR-02 throughput optimization (deferred to Increment 4 profiling).
