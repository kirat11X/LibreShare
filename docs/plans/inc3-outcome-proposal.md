# Increment 3 Outcome & Section 12 Fill Proposal

**Author:** Lane L Coder (Card G4)  
**Date:** 2026-11-06  
**Target file (frozen, orchestrator applies):** [`docs/plans/inc3.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/inc3.md) (§12)  
**References:** [`docs/test-reports/mvp-acceptance-secure.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/mvp-acceptance-secure.md), [`docs/test-reports/inc3-spikes.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/inc3-spikes.md), [`docs/plans/inc3-p3-tests.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/inc3-p3-tests.md), [`docs/plans/inc3-p4-tests.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/inc3-p4-tests.md), [`docs/plans/inc3-p5-tests.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/inc3-p5-tests.md), [`docs/plans/inc3-p6b-tests.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/inc3-p6b-tests.md), [`docs/plans/inc3-p7-drift.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/inc3-p7-drift.md), [`docs/test-reports/p6a-adversarial-review.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/p6a-adversarial-review.md), [`docs/plans/STATUS.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/STATUS.md).

---

## 1. Purpose

This proposal provides the exact text and real measured data to replace every `[FILL]` placeholder in Section 12 ("Outcome / deviations") of [`docs/plans/inc3.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/inc3.md).

---

## 2. Proposed Replacement Text for `docs/plans/inc3.md` Section 12

Below is the complete text for Section 12 of `docs/plans/inc3.md`, with all placeholders answered using verified measurements from the repository.

```markdown
## 12. Outcome / deviations (Final 2026-11-06, container-complete / MVP-closed)

**Scope note.** On 2026-11-05 the user scoped the active delivery target to an MVP (`docs/plans/mvp.md`). Increment 3 is therefore closed as **container-complete** and **MVP-closed**: building blocks P1–P7, P6a (engine + CLI wiring), and P8 (MVP security screens and secure engine wiring) are fully implemented and verified. P9 (Android `ReceiveService` foreground service) and P10 (extended Docker e2e) are deferred to post-MVP (`docs/plans/post-mvp-plan.md`). The CLI defaults to TLS 1.3 by default (Q2 approved); `--insecure-plaintext` is available for legacy testing and loopback benchmarks.

- **Done and proven (commands, exit codes, and counts):**
  Measured by the orchestrator under standalone lock (`flock -o /tmp/libreshare-heavy.lock`) on 2026-11-06 (evidence: `docs/test-reports/mvp-acceptance-secure.md`):
  1. `dart analyze --fatal-infos`: rc=0 (0 issues found).
  2. `dart format --output=none --set-exit-if-changed .`: rc=0 (280 files formatted, 0 changed).
  3. `grep -RnE "package:flutter|dart:ui" packages/libreshare_core/lib`: rc=1 (0 matches; pure-Dart core verified).
  4. `cd packages/libreshare_core && dart test -j 1`: rc=0, **+2591 passed, 1 skipped** (opt-in `LS_SLOW=1` 5 GiB test, duration 3:03).
  5. `cd packages/libreshare_cli && dart test -j 1`: rc=0, **+75 passed** (duration 1:04).
  6. `tools/loopback_smoke.sh 100 53879`: rc=0, **100 MiB byte-identical** (`cmp` matched, 17.9 MiB/s).
  7. `cd apps/libreshare_app && flutter test --no-pub --concurrency=2 --timeout 60s`: rc=0, **+478 passed** (verified on two consecutive standalone runs, 2:02 each).
  8. D1 secure app suite: 14 test files under `apps/libreshare_app/test/d1*_test.dart`, **+73 passed** on 3 consecutive standalone runs.
  9. P6a security suite: 12 core files + `cli_security_test.dart`, **39 / 39 standalone runs passed** (13 files x 3 runs each).
  10. `flutter build apk --debug`: rc=0 (built 09:00:16).
  11. `tools/package_prototype.sh linux android`: rc=0 (Linux x64 tarball + 4 Android APKs in `dist/prototype/`).
  12. `cd dist/prototype && sha256sum -c SHA256SUMS`: rc=0 (**5 of 5 checksums verified OK**).
  13. `tools/android_emulator_smoke.sh`: rc=0, **SMOKE PASSED (26 checks, 0 FAIL)** on Android 15 (API 35) emulator. Confirmed:
      - Linux host CLI receiver -> Android app sender: identical 6-digit SAS code displayed on both screens.
      - Android app receiver -> Linux host CLI sender: identical 6-digit SAS code displayed on both screens.
      - Key storage security (S7): app security directory mode 0700, key files mode 0600.
  *(Note: Continuous single-pass execution of the exact section 9 block into `docs/test-reports/inc3-final.md` is recorded under `[PENDING: G6]`.)*

- **Spike results S-A, S-B, S-C:**
  Documented in `docs/test-reports/inc3-spikes.md`.
  - **S-A:** `dart:io` `SecureServerSocket` and `HttpServer.bindSecure` with `requestClientCertificate: true` reject untrusted self-signed client certificates at the TLS handshake before HTTP parsing (`CERTIFICATE_VERIFY_FAILED`). Confirmed Decision D1: peer authentication cannot use TLS client certificates on first contact; application-layer `X-LS-Auth` proof header over TLS server authentication is mandatory.
  - **S-B:** `dart:io` successfully accepts self-signed P-256 certificates with no SAN when pinned via `badCertificateCallback`. Verified TLS 1.3 protocol floor enforcement (`minimumTlsProtocolVersion: tls1_3`) against OpenSSL 3.6.0 oracle.
  - **S-C:** PointyCastle 4.0.0 P-256 operations met all performance budgets: key generation 19.4 ms, deterministic RFC 6979 ECDSA signing 6.5 ms (budget 50 ms), signature verification 9.6 ms (budget 100 ms). Per-request proof signing adds only ~16 ms total overhead.

- **Deviations from this plan and why:**
  1. `kProtocolVersion` stays `'1.0'`; the secure profile reports `kProtocolVersionSecure = '1.1'` (additive; plaintext peers unchanged).
  2. Security is added through **capability interfaces** (`SecureTransferHandler extends IncomingTransferHandler`, `SecurePeerClient extends PeerClient`) instead of changing the shared interfaces; schemas live in `schemas/lsp11/`.
  3. **No sender-side SAS gate**: the receiver's Accept is the human comparison of the two 6-digit codes; the sender displays its code while awaiting receiver decision.
  4. **507 INSUFFICIENT_STORAGE** is also returned for a missing/unwritable download folder (both profiles).
  5. Receiver **idle timeout** deferred to Inc 4 (inc2 follow-up 7).
  6. A **Contacts-only device multicasts nothing of its own** (no announce/probe/bye/mDNS); a malformed `X-LS-Auth` is a stranger on every route (404), `/pair` exempt.
  7. A pinned registry entry is **unchanged** by an empty or different fingerprint in an announce; only a different non-empty one raises the key-changed flag.
  8. The secure subnet scanner ignores a custom `InfoProbe` and never follows redirects; a reset TLS handshake is `SocketException`/`NO_CONNECTION`, `InsecurePeer` only when the TLS error carries an `osError`.
  9. An absolute `relativePath` is re-rooted inside the download dir (Inc 1 behaviour kept); only `..` is rejected.
  10. A malformed `pin` (not exactly six ASCII digits) is **400 with no strike** (secure profile). `PinGuard`: 5 failures/IP/10 min block, 25 global lock + rotate, one-time PIN consumed atomically.
  11. `BlockSuggested` event after 3 user rejects of the same fingerprint within 10 min; it **never auto-blocks**.
  12. The CLI **defaults to TLS** (user delegated Q2: "whatever u think"); `--insecure-plaintext` is added to *setup lines only* in the two CLI tests, `tools/loopback_smoke.sh`, `tools/docker/**`, `deploy/docker/**`. Confirmed: snapshots directory `.toolchain/snap/` contains no `pre-flip` directory (snapshots preserved are `d1-apply-*`, `d1-isolation-*`, `d5`, and `base-manifest-*`). Direct inspection of git diff / files confirms that changes in setup-line files are strictly confined to `--insecure-plaintext` flags on receiver/sender startup invocations; no test assertions, timeouts, or expected outcomes were altered (matching `STATUS.md` P6a confirmation).
  13. New CLI exit codes: 80 (key changed), 81 (insecure peer), 82 (PIN/auth/blocked/bad pair secret), 83 (SAS aborted), 84 (identity lost).
  14. Windows uses the **file secret store** (no Windows keystore) for the MVP.

- **Bugs found and fixed across Increments and Waves:**
  Derived from package review notes (`inc3-p3-tests.md` through `inc3-p6b-tests.md`, `inc3-p7-drift.md`, `p6a-adversarial-review.md`, and `d1-fixes.md`):
  1. *PinGuard sliding window & strike boundaries (P3):* Fixed 5th strike block logic and sliding 10-minute window calculation (`pin_test.dart`).
  2. *Single-use PIN consumption atomicity (P3):* Guaranteed PIN is consumed only upon successful session registration, not on validation failure or premature connection closure.
  3. *Rate-limit ordering DOS protection (P3):* Rate limiter evaluates before reading request bodies on `POST /sessions` to prevent slow-loris body absorption.
  4. *Oversize body starvation limit (P3):* Enforced 4 MiB manifest cap for `POST /sessions` (D11) with a concurrency cap of 2 concurrent oversize body reads returning 429 `Retry-After: 5`.
  5. *HTTP Date header attachment (P3):* Ensured RFC 7231 `Date` header on all secure responses for client clock skew correction.
  6. *AE Defect 6 / 507 Insufficient Storage (P4):* Missing or unwritable download directories immediately return 507 `INSUFFICIENT_STORAGE` before session acceptance.
  7. *SAS commit/reveal race (P4):* Receiver prevents transfer acceptance before sender reveals its nonce; early accept returns 409 `CONFLICT`.
  8. *Peer key change isolation (P4):* Known peer presenting a different certificate emits `PeerKeyChanged` event and returns 403 `KEY_CHANGED`. Never auto-accepts.
  9. *Pairing MAC verification (P4):* Constant-time verification of `pairRequestMac` and `pairAckMac`, with immediate erasure of secret `S` upon pairing completion or expiry.
  10. *Log hygiene & secret sanitization (P4):* Truncated session IDs to 8-character prefixes in fine logging (`_shortId`); scrubbed private keys, PINs, tokens, and nonces from logs and exceptions.
  11. *Pre-HTTP certificate pin check (P5):* Verified pinned fingerprint in TLS `badCertificateCallback` before any HTTP byte is transmitted.
  12. *Clock skew auto-recovery (P5):* 401 `AUTH_INVALID` response with `Date` header triggers exactly one automatic timestamp skew compensation retry with a fresh nonce.
  13. *Downgrade prevention (P5):* Connecting to a plaintext peer in secure mode aborts immediately with `InsecurePeerException` without fallback to HTTP.
  14. *FileSender SAS abort handling (P5):* User cancellation during SAS comparison or reveal failure cleanly aborts with `SasAbortedException`.
  15. *AE Defect 4 / Goodbye broadcast (P6b):* Receiver shutdown broadcasts signed `ByeMessage`, dropping peers from registries in <= 1 s rather than lingering 90 s.
  16. *Goodbye verification rate limit (P6b):* Implemented 5/s verification budget to prevent CPU exhaustion from forged goodbye datagram floods.
  17. *Subnet scanner TLS validation (P6b):* Scanner connects over TLS 1.3, verifies certificate hash matches claimed `/info` fingerprint, and rejects lying peers.
  18. *Contacts-only stealth discovery (P6b):* Suppressed all multicast announces, probes, and mDNS in Contacts-only mode; silently ignores stranger probes.
  19. *Manual/QR peer sweep exemption (P6b):* Peers added via manual IP or QR link exempted from timer-based registry sweeps.
  20. *Protocol drift & vector conformance (P7):* Validated all 40 RFC 6979, HKDF, HMAC, X-LS-Auth, SAS, and pairing test vectors against implementation in `lsp11_vectors_test.dart`.
  21. *C5 independent re-verification gap closure (P6a):* Added `c5_survivors_test.dart` to enforce engine TLS alert mapping and `SecurityWiring.open(allowInsecurePeers: false)` default.
  22. *App PIN persistence & settings lifecycle (D1 Round 2):* Fixed P1-02 (leaving Settings while Change-PIN saves kept old PIN), P1-03 (selector showed Fixed + 'PIN configured' on write failure), and P1-07 (`retryWithPin` resending completed transfers).
  23. *App test isolation (D1 Round 2):* Replaced machine-wide `/proc/net/tcp` scanning in `listeningPorts` helper with process-specific `/proc/self/fd` socket inode resolution.

- **Mutation check results (M1–M10 of Section 9 mapped to named red tests):**
  Over 180 mutations executed across P3–P6b in scratch clones, with all surviving mutations caught by new test files. The 10 canonical mutations of Section 9 each turn at least one named test RED:
  - **M1 (Skip pin comparison in `ApiClient` callback):**
    - Target: `packages/libreshare_core/lib/src/client/api_client.dart`
    - Failing test: `packages/libreshare_core/test/security/pinning_test.dart` (`pinned_peer_with_other_certificate_refused_before_any_http_byte`) and `packages/libreshare_core/test/security/p6a_adversarial_test.dart` (group: *P6a mutation 2: pinned fingerprint comparison on send path*).
  - **M2 (Drop `serverFp` from signed text):**
    - Target: `packages/libreshare_core/lib/src/security/identity_proof.dart`
    - Failing test: `packages/libreshare_core/test/unit/identity_proof_test.dart` (`tampered_serverFp_rejected`, `proof_for_server_A_rejected_by_server_B`) and `packages/libreshare_core/test/security/token_test.dart` (`request binding: other server`).
  - **M3 (Let SAS ignore nonces):**
    - Target: `packages/libreshare_core/lib/src/security/sas.dart`
    - Failing test: `packages/libreshare_core/test/unit/sas_test.dart` (`reveal_with_wrong_nonce_rejected`, `known_answer_vectors`) and `packages/libreshare_core/test/security/sas_binding_receiver_test.dart` (`commit mismatch / MITM / replayed commit -> 401`).
  - **M4 (Count PIN strikes on success):**
    - Target: `packages/libreshare_core/lib/src/security/pin_guard.dart`
    - Failing test: `packages/libreshare_core/test/security/pin_test.dart` (`correct_pin_accepted`, `success never a strike`).
  - **M5 (Log the PIN):**
    - Target: `packages/libreshare_core/lib/src/security/pin_guard.dart` / `server/api_server.dart`
    - Failing test: `packages/libreshare_core/test/security/log_hygiene_test.dart` (`Level.ALL` log scanner) and `packages/libreshare_core/test/security/pin_test.dart` (`no PIN in logs/exceptions/toString`).
  - **M6 (Let `accept()` ignore SAS readiness):**
    - Target: `packages/libreshare_core/lib/src/transfer/file_receiver.dart`
    - Failing test: `packages/libreshare_core/test/security/sas_binding_receiver_test.dart` (`receiver_cannot_accept_before_reveal`) and `packages/libreshare_core/test/security/p6a_adversarial_test.dart` (group: *P6a mutation 8: first contact not auto-accepted without SAS*).
  - **M7 (Answer 403 instead of 404 to Contacts-only strangers):**
    - Target: `packages/libreshare_core/lib/src/server/api_server.dart` / `engine/libreshare_engine.dart`
    - Failing test: `packages/libreshare_core/test/security/contacts_only_server_test.dart` (`stranger vs contact on GET /info, /register, /sessions: 404 identical to unknown route`) and `packages/libreshare_core/test/security/p6a_adversarial_test.dart` (group: *P6a mutation 10: contacts-only visibility gates strangers*).
  - **M8 (Skip `bye` signature check):**
    - Target: `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart`
    - Failing test: `packages/libreshare_core/test/unit/goodbye_test.dart` (`forged_signature_ignored`, `byes rejected before signature check`).
  - **M9 (Auto-accept when commit is present):**
    - Target: `packages/libreshare_core/lib/src/transfer/file_receiver.dart`
    - Failing test: `packages/libreshare_core/test/unit/permission_test.dart` (`autoaccept_only_with_proof_pinned_and_no_commit`, `commit_present_means_no_auto_accept`) and `packages/libreshare_core/test/security/p6a_adversarial_test.dart` (group: *P6a mutation 8*).
  - **M10 (Regenerate identity silently when key is missing):**
    - Target: `packages/libreshare_core/lib/src/storage/credential_store.dart`
    - Failing test: `packages/libreshare_core/test/unit/credential_store_test.dart` (`missing key with present certificate => IdentityLost`) and `packages/libreshare_cli/test/cli_security_test.dart` (exit code 84).

- **Android:**
  Emulator verified (Android 15, API 35, x86_64, headless) with the packaged secure release build via `tools/android_emulator_smoke.sh` (26/26 PASS, identical 6-digit codes on both screens, 700/600 file modes). Physical device testing remains open. CI build status: no remote git repository is pushed (standing user constraint); local debug and release APK builds succeed cleanly (`flutter build apk --debug`, `tools/package_prototype.sh`).

- **Known limits carried forward (not fixed in Increment 3):**
  1. **Device-list send to a legacy plaintext peer ends as `NO_CONNECTION`:** When a secure engine or CLI discovers a legacy plaintext peer and attempts to send files without `--allow-insecure`, it initiates a TLS ClientHello. The plaintext receiver resets or closes the connection, resulting in a `SocketException` mapped to `FAILED(NO_CONNECTION)` rather than an application-level rejection envelope.
  2. **Server connection concurrency cap:** No connection cap on `ApiServer` (slow-loris style load remains unmitigated).
  3. **Forged `bye` datagrams:** Malicious datagrams can consume the 5/s verify budget on a busy subnet.
  4. **LRU cache flushing:** The `_certs` LRU can theoretically be flushed by a flood of distinct peer announcements.
  5. **10,000-file 413 check ordering:** The 10,000-file 413 limit is evaluated after proof authentication.
  6. **Contacts-only greeting (`_greetContacts`):** One-shot greeting has no retry or UDP fallback and may miss a peer that restarts while listed with the same key.
  7. **In-memory PIN counters:** PIN-guard strike counters reside in memory only and reset upon daemon restart.
  8. **Performance (NFR-02):** Loopback throughput is ~17.9–19.0 MiB/s against the 300 MB/s target; profiling and optimization are deferred to Increment 4.
  9. **Windows:** Windows-specific logic (DPAPI credential store, Windows Explorer toasts, `FileMode.append`+`setPosition`) has not been compiled or executed on Windows hardware.
```
