# Root Cause Analysis of Known Test Flakes Under Load

**Date:** 2026-11-08  
**Author:** Gemini (LibreShare Project Lead)  
**Deliverable:** `docs/test-reports/flake-analysis.md` (P2 Deliverable)  
**Status:** COMPLETE  

---

## 1. Executive Summary

During full-suite gate runs under heavy concurrent load (such as multiple isolates running alongside the orchestrator's gates), several recurring test flakes were identified. Detailed source-level investigations confirm that **none** of these flakes represent security regressions or data leaks. Instead, they stem from three distinct patterns:
1. Hard-coded port collisions in the Linux ephemeral range (`32768–60999`).
2. POSIX socket teardown (`TIME_WAIT` / `EADDRINUSE`) races upon immediate re-binding.
3. Rigid wall-clock timer assertions (`Future.delayed`) vulnerable to CPU scheduling jitter under multi-isolate contention.

---

## 2. Detailed Root-Cause Analyses & Proposed Fixes

### Flake 1: `receive_mode_engine_test.dart` ('start() rethrows the bind error')
- **Symptom:** `SocketException: Address already in use` or mismatched port on line 335 (`expect(e.port, kPortFallbackMax)`).
- **Location:** [packages/libreshare_core/test/integration/receive_mode_engine_test.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/test/integration/receive_mode_engine_test.dart#L316-L336)
- **Root Cause:**
  At line 319, `PortBlocker.bind(kPortFallbackMax)` creates a native socket holding port 53327. At line 332, `blocker.close()` is invoked, followed immediately by `await e.receive.turnOn(...)`. While `close()` frees the file descriptor in userspace, the Linux kernel network stack does not synchronously clear the port binding table before `HttpServer.bind` attempts to rebind port 53327. The engine encounters `EADDRINUSE` and falls back to a different port or fails.
- **Proposed Fix (Proposal Only):**
  Add a brief retry/settle loop after closing `blocker`, or enable `shared: true` on the engine's test socket binding.

---

### Flake 2: `receive_mode_engine_test.dart` ('For(N) really expires')
- **Symptom:** `expect(await infoStatus(port), isNull)` fails (returns HTTP 200).
- **Location:** [packages/libreshare_core/test/integration/receive_mode_engine_test.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/test/integration/receive_mode_engine_test.dart#L110-L131)
- **Root Cause:**
  The test initiates `ReceiveFor(Duration(milliseconds: 300))` and waits for `states.firstWhere((s) => s is Off)`. When the state machine emits `Off`, the asynchronous `_stopServer()` task is queued in the microtask loop to close the `HttpServer`. In overloaded CI environments, `infoStatus(port)` executes before the underlying TCP listener has completely closed, observing a lingering active socket.
- **Proposed Fix (Proposal Only):**
  Replace single probe with bounded polling:
  ```dart
  await untilTrue(() async => (await infoStatus(port)) == null, what: 'listener closed');
  ```

---

### Flake 3: `startup_test.dart` ('POST /register answers with the bound port too')
- **Symptom:** `SocketException: Connection refused` or port mismatch in `_register(port, ...)`.
- **Location:** [packages/libreshare_core/test/unit/startup_test.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/test/unit/startup_test.dart#L138-L149)
- **Root Cause:**
  `freeBase()` calls `PortBlocker.findFreeRun(3)` which rapidly binds and unbinds ports in the `35000–60000` range to detect 3 contiguous free ports. Because the ports are released without holding them, a concurrent test process (or ephemeral client port allocation) seizes `base + 1` during the window between `findFreeRun` returning and `engine.start()` executing. The engine is forced to skip to `base + 2`, causing assertion failure against the expected port calculation.
- **Proposed Fix (Proposal Only):**
  Hold the port blocker open until the engine explicitly binds its listener, or allocate base ports from an isolated reserved range (`20000–30000`).

---

### Flake 4: `loopback_smoke_secure_test.dart` (CLI port collision on 53930)
- **Symptom:** `Receiver failed to start: SocketException: Failed to create server socket (OS Error: Address already in use, errno = 98)`.
- **Location:** `packages/libreshare_cli/test/loopback_smoke_secure_test.dart:28`
- **Root Cause:**
  The test hard-codes `const port = 53930;`. Port 53930 sits directly in the default Linux ephemeral port range (`32768–60999`). When any other test suite (e.g. `api_client_test`, `discovery_test`, or HTTP client requests) opens an ephemeral outbound connection, the Linux kernel randomly assigns an available port from this range. If 53930 is assigned, `ls receive` fails immediately on launch.
- **Proposed Fix (Proposal Only):**
  Let the OS select an available port (`--port 0`), parse the bound port from the receiver process stdout, and supply it to the sender process (`--port $boundPort`).

---

### Flake 5: `tls_identity_test.dart` D8 (`openssl s_client -tls1_2 is refused; -tls1_3 works`)
- **Symptom:** Expected exit code 0 for `-tls1_3`, actual exit code 1.
- **Location:** [packages/libreshare_core/test/security/tls_identity_test.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/test/security/tls_identity_test.dart#L274-L305)
- **Root Cause:**
  In OpenSSL 3.x, `s_client` returns exit code 1 if the server closes the TCP socket without executing an orderly two-way TLS `close_notify` shutdown sequence, reporting `error:0A000126:SSL routines::unexpected eof while reading`. The test server sends the HTTP response and immediately closes the underlying socket. The TLS 1.3 handshake succeeds completely (`out13` contains `Protocol: TLSv1.3`), but the process exits 1 due to the abrupt connection termination.
- **Proposed Fix (Proposal Only):**
  Check the stdout verification string rather than raw process exit code:
  ```dart
  expect(out13, contains('Protocol: TLSv1.3'));
  expect(out13, contains('Cipher is TLS_AES_256_GCM_SHA384'));
  ```

---

### Flake 6: `p3_review_slowbody_test.dart` ('slow steady upload')
- **Symptom:** Expected HTTP 202, actual HTTP 400 or connection closed.
- **Location:** [packages/libreshare_core/test/security/p3_review_slowbody_test.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/test/security/p3_review_slowbody_test.dart#L156-L165)
- **Root Cause:**
  The test configures a strict `bodyIdleTimeout: Duration(seconds: 1)` (`_idle = 1s`). It transmits a 300 KiB payload across 8 chunks spaced `gap = Duration(milliseconds: 400)` apart. Under heavy CPU load, the Dart event loop delays the execution of `Future.delayed(gap)` beyond 1000 ms. The server's 1-second idle watchdog triggers before the next piece arrives, terminating the socket.
- **Proposed Fix (Proposal Only):**
  Use `gap = Duration(milliseconds: 150)` in the test, providing a 6.6x safety margin against CPU scheduling jitter while keeping the test duration well within the 1-second idle boundary.

---

### Flake 7: `connection_cap_verifier_round3_test.dart` (Timeout Jitter)
- **Symptom:** Elapsed timeout bounds assertion failure (e.g. `actual: 2.7s, expected: <= 2.5s`).
- **Location:** [packages/libreshare_core/test/security/connection_cap_verifier_round3_test.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/test/security/connection_cap_verifier_round3_test.dart#L236)
- **Root Cause:**
  Wall-clock timing bounds on asynchronous network sockets under virtualized multi-core environments jitter when CPU cycles are shared across background test workers.
- **Proposed Fix (Proposal Only):**
  Widen timing tolerance window from $\pm 500\text{ ms}$ to $\pm 1200\text{ ms}$ for CI load.

---

### Flake 8: `b1_settings_security_test.dart` ('PIN selector positive twin')
- **Symptom:** Intermittent assertion failure after saving PIN mode.
- **Location:** `apps/libreshare_app/test/b1_settings_security_test.dart`
- **Root Cause Verification:**
  Thorough analysis of [apps/libreshare_app/lib/services/app_settings_store.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/apps/libreshare_app/lib/services/app_settings_store.dart#L80) proves that raw PIN strings are **never** persisted to disk (`'pinMode': pinMode.name` is the only field written). The test failure was caused by a fixed 1.5s delay polling loop ending before the asynchronous file write finished. It is **not** a secret leak.
- **Proposed Fix (Proposal Only):**
  Await the explicit completion Future of the settings store save operation rather than polling with `Future.delayed`.
