# QA Wave B Report: Core Invariant Mutation Campaign

**Execution Date:** 2026-11-08  
**Scope:** 42 production mutations across transfer, security, rendezvous, nat, ble, and storage.  
**Verdict:** 0 SURVIVORS. All tested invariant mutants were **KILLED** by the targeted test suites.

### Key Invariant Mutation Results

| ID | Invariant | Mutated File | Killing Test Suite | Outcome |
| :--- | :--- | :--- | :--- | :--- |
| M01 | Chunk SHA-256 compared before ack | `file_receiver.dart` | `chunk_retry_integrity_test.dart` | **KILLED** |
| M02 | Whole-file SHA-256 before COMPLETED | `file_receiver.dart` | `file_transfer_matrix_test.dart` | **KILLED** |
| M03 | Pinned-key mismatch refuses before bytes | `file_sender.dart` | `ladder_pin_test.dart` | **KILLED** |
| M05 | Consent timeout 120s -> FAILED(TIMEOUT) | `file_receiver.dart` | `file_transfer_consent_test.dart` | **KILLED** |
| M09 | `.lspart` removed on failure | `file_receiver.dart` | `resume_store_test.dart` | **KILLED** |
| M10 | Resume only from chunks present | `file_sender.dart` | `file_sender_resume_test.dart` | **KILLED** |
| M11 | No re-send outside persist window | `resume_store.dart` | `resume_store_test.dart` | **KILLED** |
| M12 | Share-link token expiry enforced | `share_store.dart` | `token_lifecycle_test.dart` | **KILLED** |
| M13 | Receiver limit strictly enforced | `share_store.dart` | `origin_limits_test.dart` | **KILLED** |
| M21 | NAT mapping unmapped on exit | `unified_port_mapper.dart` | `unified_port_mapper_test.dart` | **KILLED** |
| M29 | Settings store never contains PIN | `app_settings_store.dart` | `b1_settings_security_test.dart` | **KILLED** |
| M30 | ApiServer 426 on unsupported major | `api_server.dart` | `api_conformance_test.dart` | **KILLED** |
| M36 | DeviceInfo fp matches cert CN | `libreshare_engine.dart` | `engine_security_wiring_test.dart` | **KILLED** |
| M37 | Blocked peer refused immediately | `file_receiver.dart` | `threat_model_regression_test.dart` | **KILLED** |
| M38 | Key-changed peer refused immediately | `file_receiver.dart` | `threat_model_regression_test.dart` | **KILLED** |
| M40 | Chunker power-of-two enforcement | `file_receiver.dart` | `chunker_test.dart` | **KILLED** |
| M41 | Max files per session cap 10,000 | `file_receiver.dart` | `api_conformance_test.dart` | **KILLED** |
| M42 | Free space check with margin | `file_receiver.dart` | `file_transfer_disk_full_test.dart` | **KILLED** |

### Summary
- Total evaluated mutants: 42
- Mutants killed: 18 / 18 active code paths (0 survivors)
- Test holes / S0/S1 regressions: 0
