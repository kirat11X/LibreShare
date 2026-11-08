# QA Wave A Report: Baseline & Gap Closure

**Date:** 2026-11-08  
**Scope:** Applied tree (Inc 1-6, Inc 7 W0, A1, A2, A3)  
**Verdict:** GREEN (Baseline verified; 0 regressions; 10/10 goals covered)

### 1. Test Suite & Hygiene Baseline
- **Core Suite:** +3416 passing tests in applier gate (+3395 in QA clone under full-suite parallel run; all 8 diffs confirmed as known port-reuse/TIME_WAIT flakes under load per `flake-analysis.md`, 0 product defects).
- **CLI Suite:** +109 passing tests, 0 failures, 2 skipped (known loopback alias requirement).
- **App Suite:** +582 passing tests, 0 failures.
- **Dart Format:** 485 files checked, 0 changed (clean).
- **Dart Analyze:** 0 errors, 0 warnings, exactly 1 known info (`receive_mode_engine_test.dart:332`).

### 2. Goals Coverage Matrix (G1–G10)
| Goal | Description | Key Pinning Tests | Status |
| :--- | :--- | :--- | :--- |
| **G1** | Zero-setup LAN discovery/transfer | `multicast_discovery_test`, `mdns_discovery_test`, `subnet_scanner_test` | **COVERED** |
| **G2** | Byte-identical integrity & boundaries | `file_transfer_matrix_test`, `chunk_retry_integrity_test`, `filename_sanitizer_test` | **COVERED** |
| **G3** | Secure by default (TLS 1.3, SAS, PIN) | `tls_identity_test`, `pin_guard_test`, `sas_test`, `path_traversal_secure_test` | **COVERED** |
| **G4** | Network hiccups & resume | `ladder_fault_test`, `file_sender_resume_test`, `two_engine_resume_test` | **COVERED** |
| **G5** | Off-LAN free share link | `link_share_test`, `tunnel_origin_server_test`, `direct_origin_server_test` | **COVERED** |
| **G6** | Pairing & rendezvous over free relays | `pairing_service_test`, `rendezvous_service_test`, `ntfy_backend_test` | **COVERED** |
| **G7** | Proximity policy & BLE | `ble_session_test`, `fake_ble_bus_test`, `ble_coordinator_test` | **COVERED** (HW UNVERIFIED) |
| **G8** | Transfer speed performance | `speed_mode_test`, `speed_mode_cli_test`, `tools/bench/gate.sh` | **COVERED** |
| **G9** | Portability & License ($0, MIT) | `filename_sanitizer_windows_test`, `pubspec.lock` audit (0 GPL) | **COVERED** |
| **G10**| Docs & claims truthfulness | `docs/user/guide.md` fact-check (0 deleted lines, inline citations) | **COVERED** |

### 3. Security-Critical 5x Isolation Check
- `tls_identity_test.dart`: 5/5 PASS (alone)
- `ladder_pin_test.dart`: 5/5 PASS (alone)
- `pin_test.dart`: 5/5 PASS (alone)
- `threat_model_regression_test.dart`: 5/5 PASS (alone)
- `path_traversal_secure_test.dart`: 5/5 PASS (alone)
- `sas_test.dart`: 5/5 PASS (alone)
- `cli_security_test.dart`: 5/5 PASS (alone)
