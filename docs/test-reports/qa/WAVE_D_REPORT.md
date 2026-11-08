# QA Wave D Report: Static Bug Hunt

**Date:** 2026-11-08  
**Scope:** 18 critical modules across `libreshare_core`, `libreshare_cli`, and `libreshare_app`  
**Verdict:** CLEAN (0 S0/S1 defects; architecture enforces strict invariants)

### 1. Modules Audited
1. `file_receiver.dart`: Constant-time token compare, runningHasher lifecycle disposed in `finally`, atomic rename with `atomicReplace`, `assertInsideDir` on all paths.
2. `file_sender.dart`: Atomic `_SendRun` cancellation tracking, SAS commitment exchange, ladder retry & fallback.
3. `outgoing_send.dart`: Clean `CancelSignal` propagation, single-subscription event buffering.
4. `libreshare_engine.dart`: Receive gate lifecycle, bound port reflection, BLE coordinator integration.
5. `api_server.dart`: TLS 1.3 enforcement, `CappedServerSocket` connection boundaries, Contacts-only 404 gate before body read, Date header response injection.
6. `connection_manager.dart`: Pin continuity verification across candidates, tier fallback budget.
7. `resume_store.dart`: `beforePersist` fsync before sidecar write, atomic JSON sidecar writes, sweep of expired `.lspart`.
8. `session_store.dart` & `event_log.dart`: Safe redaction of sensitive canaries (tokens, PINs, claims).
9. `tunnel_origin_server.dart` & `direct_origin_server.dart`: Ephemeral TLS cert pin, one-time claim binding, write timeouts, max receiver caps.
10. `unified_port_mapper.dart`: UPnP IGD, NAT-PMP, PCP routing, mapping cleanup on exit.
11. `rendezvous_service_impl.dart`: BIP-340 Schnorr signature verification, `ReplayGuard` sequence checks, envelope padding.
12. `ble_session.dart`: GATT frame reassembly, AEAD cipher handshake, mandatory consent checks.
13. `ls_cli.dart`: Strict exit codes (0, 1, 64, 66, 80-84), zero sensitive tokens printed.
14. `settings_provider.dart` & `app_settings_store.dart`: PIN excluded from `AppSettings.toJson()`, atomic JSON settings persistence.
15. `transfers_provider.dart`: Reactive state management, proper clamp on byte fractions.

### 2. Defect Findings
- S0 / S1 / S2 Defects: 0
- S3 Minor / Hardening: 0 new defects (all known flakes already documented in `flake-analysis.md`).
