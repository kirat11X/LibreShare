# Audit of Hard-Coded Ports in Test Suites

**Date:** 2026-11-08  
**Author:** Gemini (LibreShare Project Lead)  
**Deliverable:** `docs/test-reports/fixed-ports.md` (P2 Deliverable)  
**Status:** COMPLETE  

---

## 1. Executive Summary

This report catalogues every hard-coded TCP/UDP port across `packages/*/test` and `apps/*/test`. On Linux kernels, the default ephemeral port range (`/proc/sys/net/ipv4/ip_local_port_range`) is **`32768–60999`**. Tests binding fixed ports within this range are inherently vulnerable to non-deterministic collisions (`SocketException: Address already in use`) whenever the OS kernel allocates one of those ports to a concurrent socket or client connection.

---

## 2. Hard-Coded Ports Matrix

| File | Line | Port | In Linux Ephemeral Range (32768–60999)? | Collision Risk & Potential Colliders |
|---|---|:---:|:---:|---|
| `packages/libreshare_cli/test/loopback_smoke_secure_test.dart` | 28 | **53930** | **YES** (53930) | **HIGH.** Smoked receiver bind. If an ephemeral socket takes 53930 during gate parallel execution, test aborts with `SocketException`. |
| `packages/libreshare_cli/test/loopback_smoke_secure_test.dart` | 48 | **53931** | **YES** (53931) | **HIGH.** Same risk as 53930. |
| `packages/libreshare_cli/test/q_cli_discovery_test.dart` | 33 | **53320** | **YES** (53320) | **MEDIUM.** Collides with `startup_test`, `engine_discovery_test`, or real engine fallback. |
| `packages/libreshare_core/test/integration/probe_ephemeral_reply_test.dart` | 21 | **53395** | **YES** (53395) | **HIGH.** Fixed probe test port. Collides with concurrent test sockets. |
| `packages/libreshare_core/test/integration/probe_ephemeral_reply_test.dart` | 69 | **53396** | **YES** (53396) | **HIGH.** Fixed probe test port. |
| `packages/libreshare_core/test/unit/api_client_test.dart` | 59 | **53320** | **YES** (53320) | **LOW.** Target address of stubbed HTTP client; does not bind. |
| `packages/libreshare_core/test/unit/api_client_test.dart` | 81 | **53399** | **YES** (53399) | **LOW.** Target address of stubbed HTTP client. |
| `packages/libreshare_core/test/unit/candidate_test.dart` | 46, 67, 108 | **45454** | **YES** (45454) | **LOW.** Mock candidate DTO test; does not bind socket. |
| `packages/libreshare_core/test/unit/candidate_test.dart` | 83 | **50000** | **YES** (50000) | **LOW.** Mock candidate DTO test. |
| `packages/libreshare_core/test/unit/connection_manager_test.dart` | 108, 140 | **5000** | NO (5000) | **LOW.** Mock candidate port; does not bind socket. |
| `packages/libreshare_core/test/unit/event_log_test.dart` | 162, 209 | **52000** | **YES** (52000) | **LOW.** DTO fixture only; does not bind socket. |
| `packages/libreshare_core/test/unit/origin_pull_connection_test.dart` | 119 | **65432** | NO (65432) | **LOW.** Intentionally closed port used to assert connection failure. |
| `packages/libreshare_core/test/integration/tunnel_fallback_test.dart` | 73 | **65431** | NO (65431) | **LOW.** Intentionally dead port used to assert fallback. |
| `packages/libreshare_core/test/helpers/port_blocker.dart` | 86 | **35000–60000** | **YES** | **MEDIUM.** `findFreeRun` loops over `35000 + (attempt * 17) % 25000` to find a run of free ports. Rapid bind/unbind races with ephemeral kernel allocations. |
| `packages/libreshare_core/test/unit/startup_test.dart` | 1 | **53318–53327** | **YES** | **MEDIUM.** Tests fallback progression across protocol ports. Collides if another test engine runs simultaneously on loopback. |
| `packages/libreshare_core/test/integration/receive_mode_engine_test.dart` | 319, 335 | **53327** (`kPortFallbackMax`) | **YES** | **HIGH.** Directly binds `53327`, closes it, and expects immediate re-bind. Triggers POSIX `TIME_WAIT` / `EADDRINUSE` races. |

---

## 3. Recommended Remediation Strategy (Proposal Only)

Per project policy, existing tests are **NOT** edited directly without user approval. The following proposals are recommended to eliminate port flakes:

1. **Port Allocation Seam (`EphemeralPortServer`):**
   - In integration tests requiring real listeners (such as `loopback_smoke_secure_test`), always bind to port `0`:
     ```dart
     final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
     final actualPort = server.port;
     ```
   - Pass `actualPort` to the client via CLI flags (`--port $actualPort`).

2. **SO_REUSEADDR on Native Sockets (`PortBlocker`):**
   - In `PortBlocker`, set `SO_REUSEADDR` (`setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, ...)`), or avoid probing ephemeral ranges. Instead, probe in the user-assigned test range below 32768 (e.g. `20000–30000`) where Linux ephemeral allocations never occur.

3. **Settling Delay on Sockets Re-bound:**
   - In `receive_mode_engine_test.dart` line 332, allow a 50 ms settling window after closing `PortBlocker` before calling `turnOn()`, or use an isolated preferred port range.
