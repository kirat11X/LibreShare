# Increment 3 Traceability Matrix Update Proposal

**Author:** Lane L Coder (Card G5)  
**Date:** 2026-11-06  
**Target file (frozen, orchestrator applies):** [`docs/traceability.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/traceability.md)  
**References:** [`docs/plans/INC3_CLOSURE_PLAN.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/INC3_CLOSURE_PLAN.md) (Section 3 Track E, G5), [`docs/plans/STATUS.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/STATUS.md), [`docs/test-reports/mvp-acceptance-secure.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/mvp-acceptance-secure.md), [`docs/plans/inc3.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/inc3.md) (§4.1, §5, §12).

---

## 1. Summary of Changes

This proposal updates `docs/traceability.md` to reflect the completion of Increment 3 (container-complete / MVP-closed):
1. **Status value addition:** Define `inc3-done` (Increment 3 share fully proven by automated tests that pass locally across core, CLI, and app suites; on-device real-phone and Windows native CI remain open).
2. **FR-05 (TLS & Mutual Authentication):** Updated from `building blocks reviewed; engine wiring pending` to `inc3-done`.
3. **FR-06 (Consent, Timeout & SAS Verification):** Updated from `building blocks reviewed; engine wiring pending` to `inc3-done`.
4. **FR-16 (Security Controls: PinGuard, TOFU, Rate Limits, Path Sanitization):** Updated from `building blocks reviewed; engine wiring pending` to `inc3-done`.
5. **FR-18 (Receive Mode & Contacts-Only Stealth):** Updated from `building blocks reviewed, engine wiring pending (Contacts-only)` to `inc3-done (Receive mode + Contacts-only stealth); Android ReceiveService FGS deferred to post-MVP`.
6. **NFR-04 (Security Guarantees: Crypto, Pinning, Traversal, Log Hygiene):** Updated from `building blocks reviewed; engine wiring pending (Inc 3); planned (Inc 5)` to `inc3-done (Inc 3 LAN/TLS crypto guarantees); planned (Inc 5 tunnel crypto)`.
7. **FR-22 (New Row - Pairing and Contacts):** Added new row for out-of-band device pairing (QR/link with `s=`), mutual contact pinning with K_pair derivation, and contact management (CLI + App). (Note: FR-19 through FR-21 are reserved by Design 02 for Nostr/ntfy rendezvous).
8. **Threat Model Table:** Update status for Rogue device spamming, MITM / ARP spoof, Unauthorized download, Disk exhaustion, and Replay mitigations to `inc3-done`.

---

## 2. Proposed Edits to `docs/traceability.md`

### 2.1 Status Values Definition (Section 1)

In `docs/traceability.md` line 5, append `inc3-done`:

```markdown
**Status values.** `planned` - not started. `inc1-in-progress` - being built in Increment 1. `inc1-done` - the Increment 1 share of the requirement is proven by automated tests that pass (named in the row); a later increment named in the *Increment* column may extend it. `inc2-done` - the Increment 2 share of the requirement is proven by automated tests that pass locally (named in the row); CI has not run them yet. `inc2-core-done` - the headless share (core + CLI) is proven by named passing tests; the app screen, Docker e2e or CI part named in the row is still open. `inc3-done` - the Increment 3 share of the requirement is proven by automated tests that pass locally (named in the row) across core, CLI, and app suites; physical phone checklist, Windows native builds, and CI remain open. `done` - fully proven by automated tests that pass in CI. `manual` - proven by a documented manual test in `docs/test-reports/`.
```

---

### 2.2 Functional Requirements Table Rows

Replace existing rows FR-05, FR-06, FR-16, FR-18 and insert new row FR-22:

| ID | Requirement summary | Module(s) | Automated test(s) | Increment | Status |
|---|---|---|---|---|---|
| FR-05 | Peers communicate over a mutually authenticated TLS channel with pinned fingerprints; the sender requests permission via `POST /sessions`. Insecure plaintext allowed only via explicit opt-in (`--insecure-plaintext` / `SecurityConfig.plaintext`). | `security/{cert_factory,crypto_primitives,identity_proof,trust_store,tls_context}.dart`, `server/api_server.dart`, `client/api_client.dart`, `engine/{libreshare_engine,security_wiring}.dart`, `packages/libreshare_cli/lib/ls_cli.dart` | `unit/cert_factory_test.dart` (15), `unit/crypto_primitives_test.dart` (18), `unit/identity_proof_test.dart` (27), `unit/api_client_tls_test.dart` (30), `security/pinning_test.dart` (28), `security/tls_identity_test.dart` (15), `security/engine_tls_handshake_test.dart` (13), `security/downgrade_test.dart` (20), `security/c5_survivors_test.dart` (2), `integration/secure_two_engine_test.dart` (10), `packages/libreshare_cli/test/cli_security_test.dart` (34: TLS default, reject downgrade without `--allow-insecure`), `apps/libreshare_app/test/d1_secure_engine_test.dart` | 3 | inc3-done |
| FR-06 | The receiver accepts or rejects an incoming session: reject -> `FAILED(REJECTED)`; 120 s of silence -> `FAILED(TIMEOUT)`; interactive 6-digit SAS verification code comparison (`SasReady`) prevents relay and MITM before accept. | `session/transfer_session.dart`, `transfer/{file_receiver,file_sender}.dart`, `server/api_server.dart`, `security/consent_policy.dart`, `engine/libreshare_engine.dart`, `apps/libreshare_app/lib/screens/transfer_screen.dart`, `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart` | `unit/permission_test.dart` (43: auto-accept matrix, timeout race, pinning on accept), `unit/receiver_secure_session_test.dart` (46: trust check, check order), `unit/file_sender_sas_test.dart` (34: commit/reveal, `SasReady(outgoing:true)`), `security/sas_binding_receiver_test.dart` (32: commit mismatch -> 401, no accept before reveal), `integration/secure_two_engine_test.dart` (10), `packages/libreshare_cli/test/cli_security_test.dart` (SAS interactive code prompt), `apps/libreshare_app/test/b1_incoming_security_test.dart`, `apps/libreshare_app/test/d1b_sender_dialog_test.dart`, `tools/android_emulator_smoke.sh` (26/26: same 6-digit code on sender and receiver screens in both directions) | 3 | inc3-done |
| FR-16 | Security: TLS 1.3 + certificate fingerprint pinning, TOFU + SAS, optional PIN (5 failures/IP -> 10 min block; 25 global failures -> lock + rotate), rate limits (10 sessions/min, 2 concurrent oversize body reads), consent dialog, filename sanitization (path traversal contained in download folder). | `security/*`, `server/rate_limiter.dart`, `transfer/filename_sanitizer.dart`, `engine/security_wiring.dart`, `packages/libreshare_cli/lib/ls_cli.dart`, `apps/libreshare_app/lib/screens/settings_screen.dart` | `security/pinning_test.dart` (28), `security/key_change_test.dart` (15), `security/rate_limit_test.dart` (10), `security/pin_test.dart` (40: policy off/fixed/window, TTL, per-IP block, global lock/rotate, single-use consume atomicity), `security/oversize_test.dart` (22: 4 MiB session cap, 10k files), `security/token_test.dart` (48), `security/engine_tofu_test.dart` (17), `security/log_hygiene_test.dart` (Level.ALL secret sanitization), `security/p6a_adversarial_test.dart` (6 groups, 10/10 mutations killed), `integration/path_traversal_secure_test.dart` (4), `apps/libreshare_app/test/d1_pin_persistence_test.dart`, `apps/libreshare_app/test/d1b_pin_settings_test.dart`, `apps/libreshare_app/test/d1_two_engine_pin_test.dart` | 3 | inc3-done |
| FR-18 | Receive mode (roadmap Inc 2, design 01 section 1): Off / For(N) / Always with visibility `everyone` or `contacts`; Off = listener closed and send-only probe announced; drain window on expiry (new sessions get 409 `BUSY`). Contacts-only stealth visibility suppresses multicast announces/probes/mDNS and answers strangers with 404 indistinguishable from unknown routes. | `receive/{receive_state,receive_gate,receive_scheduler,receive_settings,receive_controller}.dart`, `storage/receive_settings_store.dart`, `discovery/multicast_discovery.dart`, `server/api_server.dart`, `engine/libreshare_engine.dart`, `packages/libreshare_cli/lib/ls_cli.dart` (`ls receive --visibility contacts`) | `unit/receive_controller_test.dart` (37), `unit/receive_settings_store_test.dart` (11), `integration/receive_mode_engine_test.dart` (13), `security/contacts_only_server_test.dart` (19: stranger 404, pair exempt), `security/contacts_only_discovery_test.dart` (14: probe/reply filter, silent on subnet), `security/engine_contacts_only_test.dart` (10), `integration/contacts_only_engine_test.dart` (10), `packages/libreshare_cli/test/cli_security_test.dart` (`ls receive --visibility contacts`). Note: Android background `ReceiveService` foreground service is tracked post-MVP in Module F / P9. | 2 (Receive mode); 3 (Contacts-only) | inc3-done (Receive mode + Contacts-only stealth); Android ReceiveService FGS deferred to post-MVP |
| FR-22 | Pairing and contacts: out-of-band device pairing via QR code or `libreshare://pair` URI with secret `s=`, mutual certificate pinning, derivation of `K_pair` for future rendezvous (Inc 6), and contact list management (list, add, remove, block). | `security/pairing_service.dart`, `storage/{device_registry,credential_store,file_secret_store}.dart`, `security/trust_store.dart`, `engine/libreshare_engine.dart`, `packages/libreshare_cli/lib/ls_cli.dart` (`ls pair`, `ls contacts`), `apps/libreshare_app/lib/screens/settings_screen.dart` | `unit/pairing_test.dart` (45: request MAC, ack MAC, K_pair derivation, expiry, single-use S), `unit/device_registry_test.dart` (LRU bound 512, atomic write, 0600 modes, corrupt backup), `unit/trust_store_test.dart`, `conformance/lsp11_vectors_test.dart` (vector 4 pairing MACs and K_pair), `packages/libreshare_cli/test/cli_security_test.dart` (`ls pair --show`, `ls pair --scan`, `ls contacts`), `apps/libreshare_app/test/b5_open_contacts_test.dart` (4), `apps/libreshare_app/test/settings_screen_test.dart` (fingerprint display & copy) | 3 | inc3-done |

---

### 2.3 Non-Functional Requirements Table Row

Replace row NFR-04:

| ID | Requirement summary | Module(s) | Automated test(s) | Increment | Status |
|---|---|---|---|---|---|
| NFR-04 | Security guarantees: wrong certificate refused before HTTP bytes, wrong PIN x5 blocked (sliding 10 min window), 25 global PIN strikes triggers lock and rotation, traversal contained, SAS commit-reveal prevents MITM, secret scrubbing from logs/exceptions, tunnel origin capture never contains plaintext pattern. | `security/*`, `server/api_server.dart`, `client/api_client.dart`, `transfer/filename_sanitizer.dart`, `engine/security_wiring.dart`, `security/tunnel_crypto.dart` (Inc 5) | `security/pinning_test.dart`, `security/key_change_test.dart`, `security/rate_limit_test.dart`, `security/pin_test.dart`, `security/oversize_test.dart`, `security/token_test.dart`, `security/log_hygiene_test.dart`, `security/downgrade_test.dart`, `security/p6a_adversarial_test.dart` (10 mutations killed), `security/c5_survivors_test.dart`, `integration/path_traversal_secure_test.dart`; groundwork: `unit/filename_sanitizer_test.dart`, `unit/sanitizer_fuzz_test.dart` | 3 (LAN/TLS); 5 (Tunnel) | inc3-done (Inc 3 LAN/TLS crypto guarantees); planned (Inc 5 tunnel crypto) |

---

### 2.4 Threat Model to Test Updates

Replace rows in Section 5 ("Threat model to test"):

| Threat | Mitigation | Test | Increment | Status |
|---|---|---|---|---|
| Rogue device spamming | Consent dialog, rate limits (10/min, 2 oversize), block list (`BlockSuggested`), PIN guard (5 strikes/IP -> 10 min block) | `unit/rate_limiter_test.dart`, `security/rate_limit_test.dart`, `security/pin_test.dart`, `unit/block_suggestion_test.dart`, `security/oversize_test.dart` | 1 / 3 | inc3-done |
| MITM / ARP spoof | TLS 1.3 + certificate fingerprint pinning, SAS 6-digit commit/reveal, out-of-band QR pairing | `security/pinning_test.dart`, `security/tls_identity_test.dart`, `security/sas_binding_receiver_test.dart`, `unit/file_sender_sas_test.dart`, `unit/identity_proof_test.dart`, `security/engine_tofu_test.dart`, `security/p6a_adversarial_test.dart`, `security/c5_survivors_test.dart` | 3 | inc3-done |
| Unauthorized download | No LAN download API; 128-bit session token + fragment key; single-use token invalidated on `/complete` or expiry | `security/token_test.dart`, `conformance/api_conformance_secure_test.dart` | 3 / 5 | inc3-done (Inc 3 LAN share); planned (Inc 5 tunnel share) |
| Disk exhaustion | Free space >= totalSize + 64 MiB before accept; 507 `INSUFFICIENT_STORAGE` on missing or unwritable download directory | `unit/receiver_secure_dir_test.dart`, `unit/receiver_secure_session_test.dart`, `security/oversize_test.dart` | 3 | inc3-done |
| Replay | Unique UUIDv4 session IDs, single-use `X-LS-Auth` nonce cache, timestamp +-120 s window check with single skew-compensation retry | `security/token_test.dart`, `unit/identity_proof_test.dart`, `unit/api_client_clock_skew_test.dart`, `unit/goodbye_test.dart` | 3 | inc3-done |

---

## 3. Measured Pass Counts & Evidence (from STATUS.md & mvp-acceptance-secure.md)

All tests passed locally under standalone heavy lock (`flock -o /tmp/libreshare-heavy.lock`):

| Suite | Command | Exit Code | Pass Count | Duration |
|---|---|---|---|---|
| Core Library | `cd packages/libreshare_core && dart test -j 1` | 0 | **+2591 passed, 1 skipped** (opt-in `LS_SLOW=1`) | 3:03 |
| CLI Tool | `cd packages/libreshare_cli && dart test -j 1` | 0 | **+75 passed** | 1:04 |
| Flutter App | `cd apps/libreshare_app && flutter test --concurrency=2` | 0 | **+478 passed** (verified twice consecutively) | 2:02 |
| D1 Security Wiring | `apps/libreshare_app/test/d1*_test.dart` (14 files) | 0 | **+73 passed** (3 consecutive runs) | ~0:45 |
| P6a Security Suite | 12 core files + `cli_security_test.dart` (3 runs each) | 0 | **39 / 39 runs passed** | ~1:15 |
| Loopback Transfer | `tools/loopback_smoke.sh 100 53879` | 0 | **100 MiB byte-identical** (17.9 MiB/s) | 5.6 s |
| Emulator Smoke | `tools/android_emulator_smoke.sh` | 0 | **26 / 26 PASS** (identical 6-digit code on both screens) | 2:11 |
| Static Analysis | `dart analyze --fatal-infos` | 0 | 0 issues | 3.5 s |
| Code Formatting | `dart format --output=none --set-exit-if-changed .` | 0 | 280 files, 0 changed | 1.8 s |
| Clean Seams | `grep -RnE "package:flutter\|dart:ui" packages/libreshare_core/lib` | 1 | 0 matches (exit 1 = clean) | 0.2 s |
| Packaging & Checksums | `tools/package_prototype.sh linux android` | 0 | Linux tarball + 4 APKs; `sha256sum -c` 5/5 OK | 2:50 |
