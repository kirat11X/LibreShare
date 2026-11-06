# Increment 3 Flake Hunt Log - 2026-11-05

Measured on: 2026-11-05 (Card A2: Flake hunt for Inc 3 test files)
Toolchain: project-local Dart via `source tools/env.sh`
Methodology: Each Inc 3 test file was executed 3 consecutive times in isolation (`(cd packages/libreshare_core && dart test <file>)`).

## Summary

| Category | Count | Files |
|---|---|---|
| **Flaky (`flaky (n/3)`)** | **0** | None |
| **Red (`red (3/3)`)** | **2** | `test/security/p5_review_test.dart`, `test/security/pinning_test.dart` |
| **Consistent Pass (`3/3 green`)** | **48** | See table below |
| **Total Test Files Evaluated** | **50** | 24 security, 5 conformance, 16 unit, 5 integration |

---

## 1. Flaky Files (Intermittent Failures)

None. Zero test files exhibited flaky / intermittent behavior across 3 runs.

---

## 2. Red Files (Consistent 3/3 Failures)

These files failed on all 3 runs (not flaky). Both failures are caused by `SocketException: Failed to create server socket (OS Error: Address already in use, errno = 98)` when `RawTlsPeer.start` attempts to immediately re-bind to the same port of a just-closed peer while the port remains in `TIME_WAIT`.

### `test/security/p5_review_test.dart`
- **Results**: Run 1 rc=1, Run 2 rc=1, Run 3 rc=1 (`red`)
- **Failing test**:
  - `pin check covers every connection a first-contact client refuses a different certificate later`
- **Root cause stack**:
  - `SocketException: Failed to create server socket (OS Error: Address already in use, errno = 98), address = 127.0.0.1, port = 42141` at `test/helpers/p5_raw_peer.dart:312` from `test/security/p5_review_test.dart:193`

### `test/security/pinning_test.dart`
- **Results**: Run 1 rc=1, Run 2 rc=1, Run 3 rc=1 (`red`)
- **Failing tests**:
  - `certificate swapped mid-session pinned client refuses the swapped certificate; the new peer sees zero bytes`
  - `certificate swapped mid-session first-contact client locks onto the first certificate it saw (SPEC-GAP, safer reading)`
- **Root cause stack**:
  - `SocketException: Failed to create server socket (OS Error: Address already in use, errno = 98)` at `test/helpers/p5_raw_peer.dart:312` from `test/security/pinning_test.dart:342` and `pinning_test.dart:363`

---

## 3. Complete Test File Results (All 50 Files)

| File | Status | Run 1 rc | Run 2 rc | Run 3 rc | Test Counts / Summary |
|---|---|---|---|---|---|
| `test/security/contacts_only_discovery_test.dart` | `3/3 green` | 0 | 0 | 0 | +14: All tests passed! |
| `test/security/contacts_only_server_test.dart` | `3/3 green` | 0 | 0 | 0 | +19: All tests passed! |
| `test/security/downgrade_test.dart` | `3/3 green` | 0 | 0 | 0 | +20: All tests passed! |
| `test/security/engine_contacts_only_test.dart` | `3/3 green` | 0 | 0 | 0 | +10: All tests passed! |
| `test/security/engine_tls_handshake_test.dart` | `3/3 green` | 0 | 0 | 0 | +13: All tests passed! |
| `test/security/engine_tofu_test.dart` | `3/3 green` | 0 | 0 | 0 | +17: All tests passed! |
| `test/security/key_change_test.dart` | `3/3 green` | 0 | 0 | 0 | +15: All tests passed! |
| `test/security/log_hygiene_receiver_test.dart` | `3/3 green` | 0 | 0 | 0 | +12: All tests passed! |
| `test/security/log_hygiene_test.dart` | `3/3 green` | 0 | 0 | 0 | +2: All tests passed! |
| `test/security/oversize_test.dart` | `3/3 green` | 0 | 0 | 0 | +22: All tests passed! |
| `test/security/p3_review_gate_test.dart` | `3/3 green` | 0 | 0 | 0 | +9: All tests passed! |
| `test/security/p3_review_slowbody_test.dart` | `3/3 green` | 0 | 0 | 0 | +5: All tests passed! |
| `test/security/p3_review_test.dart` | `3/3 green` | 0 | 0 | 0 | +13: All tests passed! |
| `test/security/p4_review_test.dart` | `3/3 green` | 0 | 0 | 0 | +39: All tests passed! |
| `test/security/p5_review_test.dart` | `red` | 1 | 1 | 1 | +12 -1: 1 failure (port bind in use) |
| `test/security/p6b_review_test.dart` | `3/3 green` | 0 | 0 | 0 | +15: All tests passed! |
| `test/security/pin_shape_test.dart` | `3/3 green` | 0 | 0 | 0 | +67: All tests passed! |
| `test/security/pin_test.dart` | `3/3 green` | 0 | 0 | 0 | +40: All tests passed! |
| `test/security/pinning_test.dart` | `red` | 1 | 1 | 1 | +26 -2: 2 failures (port bind in use) |
| `test/security/rate_limit_test.dart` | `3/3 green` | 0 | 0 | 0 | +10: All tests passed! |
| `test/security/sas_binding_receiver_test.dart` | `3/3 green` | 0 | 0 | 0 | +32: All tests passed! |
| `test/security/sas_binding_test.dart` | `3/3 green` | 0 | 0 | 0 | +6: All tests passed! |
| `test/security/tls_identity_test.dart` | `3/3 green` | 0 | 0 | 0 | +15: All tests passed! |
| `test/security/token_test.dart` | `3/3 green` | 0 | 0 | 0 | +48: All tests passed! |
| `test/conformance/api_conformance_secure_test.dart` | `3/3 green` | 0 | 0 | 0 | +40: All tests passed! |
| `test/conformance/api_conformance_test.dart` | `3/3 green` | 0 | 0 | 0 | +78: All tests passed! |
| `test/conformance/lsp11_conformance_test.dart` | `3/3 green` | 0 | 0 | 0 | +121: All tests passed! |
| `test/conformance/lsp11_vectors_test.dart` | `3/3 green` | 0 | 0 | 0 | +40: All tests passed! |
| `test/conformance/schema_conformance_test.dart` | `3/3 green` | 0 | 0 | 0 | +110: All tests passed! |
| `test/unit/goodbye_test.dart` | `3/3 green` | 0 | 0 | 0 | +26: All tests passed! |
| `test/unit/peer_registry_remove_test.dart` | `3/3 green` | 0 | 0 | 0 | +27: All tests passed! |
| `test/unit/announce_fingerprint_test.dart` | `3/3 green` | 0 | 0 | 0 | +10: All tests passed! |
| `test/unit/subnet_scanner_tls_test.dart` | `3/3 green` | 0 | 0 | 0 | +10: All tests passed! |
| `test/unit/peer_registrar_tls_test.dart` | `3/3 green` | 0 | 0 | 0 | +9: All tests passed! |
| `test/unit/permission_test.dart` | `3/3 green` | 0 | 0 | 0 | +43: All tests passed! |
| `test/unit/pairing_test.dart` | `3/3 green` | 0 | 0 | 0 | +45: All tests passed! |
| `test/unit/receiver_secure_session_test.dart` | `3/3 green` | 0 | 0 | 0 | +46: All tests passed! |
| `test/unit/receiver_secure_dir_test.dart` | `3/3 green` | 0 | 0 | 0 | +14: All tests passed! |
| `test/unit/block_suggestion_test.dart` | `3/3 green` | 0 | 0 | 0 | +22: All tests passed! |
| `test/unit/api_client_tls_test.dart` | `3/3 green` | 0 | 0 | 0 | +30: All tests passed! |
| `test/unit/api_client_clock_skew_test.dart` | `3/3 green` | 0 | 0 | 0 | +13: All tests passed! |
| `test/unit/file_sender_sas_test.dart` | `3/3 green` | 0 | 0 | 0 | +34: All tests passed! |
| `test/unit/send_result_refusal_test.dart` | `3/3 green` | 0 | 0 | 0 | +16: All tests passed! |
| `test/unit/security_wiring_test.dart` | `3/3 green` | 0 | 0 | 0 | +16: All tests passed! |
| `test/unit/api_server_stop_p3_test.dart` | `3/3 green` | 0 | 0 | 0 | +8: All tests passed! |
| `test/integration/goodbye_registry_test.dart` | `3/3 green` | 0 | 0 | 0 | +4: All tests passed! |
| `test/integration/secure_two_engine_test.dart` | `3/3 green` | 0 | 0 | 0 | +13: All tests passed! |
| `test/integration/contacts_only_engine_test.dart` | `3/3 green` | 0 | 0 | 0 | +10: All tests passed! |
| `test/integration/path_traversal_secure_test.dart` | `3/3 green` | 0 | 0 | 0 | +12: All tests passed! |
| `test/integration/goodbye_engine_test.dart` | `3/3 green` | 0 | 0 | 0 | +5: All tests passed! |
