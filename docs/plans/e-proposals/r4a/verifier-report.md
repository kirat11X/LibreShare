# R4a verifier report (stage 3, a different agent from tester and coder)

Verifier clone: `.toolchain/scratch/e5-r4a-verify/clone` (rsync of the real tree at 2026-11-06 13:52, then `patch -p1 < patch.diff`: rc 0, no fuzz, no .rej/.orig; test file copied to `packages/libreshare_core/test/security/`). Mutation copy: `.toolchain/scratch/e5-r4a-verify/mut`. Raw logs and the stamped summary: `.toolchain/scratch/e5-r4a-verify/logs/` (summary copy: `verifier-tests/run-summary.txt`). No edit of the real tree except this folder. All heavy runs under `flock -o /tmp/libreshare-heavy.lock`, one test process at a time.

## Verdict: SAFE AFTER FIXES (one small fix recommended before applying; applying as is does not make anything worse than today)

Nothing found that serves plaintext on the TLS profile, changes the remote address, leaks slots, or breaks restarts. One real cap bypass (half-closed sockets, finding 1) and one hole in the slow-loris story (no TLS handshake timeout, finding 2). Finding 1 has a validated one-line fix: with it all 12 tester tests and all 20 verifier probes pass (32/32, `mut-fixA`).

## 1. Line-by-line review (file:line in the patched files)

- **Where `request.connectionInfo.remoteAddress` comes from now.** dart:io builds it from the socket object handed to `HttpServer.listenOn` (`_HttpConnectionInfo.create(socket)`, SDK `http_impl.dart:3780`, reads `socket.remoteAddress`). That object is now the `_TrackedSocket` / `_TrackedSecureSocket`, whose getter forwards to the real socket: `capped_server_socket.dart:233` (`remoteAddress => _inner.remoteAddress`; `port`/`address`/`remotePort` likewise forwarded). `api_server.dart:323` still does `http.connectionInfo?.remoteAddress.address` and puts it in the request context (`kRemoteAddressContextKey`); the rate limiter (`_remoteOf`, lines ~741/922) and the handler's `remoteAddress` parameter (what `PinGuard.check` receives) use that same string. Proved by behaviour: X1 (TLS handler sees 127.0.0.4), X1b (plain handler sees 127.0.0.5).
- **Is the per-IP key the same value?** Yes. `capped_server_socket.dart:72` takes `socket.remoteAddress.address` from the raw accepted socket; the other consumers take `remoteAddress.address` of the same underlying socket (after `secureServer` the TLS socket wraps the same fd). Nobody normalises: both are the raw `InternetAddress.address` string, so IPv6 / IPv4-mapped handling is identical to before (and `bindAddress` defaults to `anyIPv4`, so mapped forms cannot occur by default). One theoretical difference: if a socket's `remoteAddress` throws at accept, the cap destroys it (lines 71-75); before, dart:io would have used `'unknown'`.
- **Failed TLS handshake.** `capped_server_socket.dart:127-131`: `_handshaking--`, `socket.destroy()`, `release()`. Slot freed, TCP socket closed. Verified: P3 (100 abandoned handshakes, 5 shapes, slots usable after 0.46 s), P3b (global slots), P4b. Side effect: the handshake error is now swallowed; before, `RawSecureServerSocket` forwarded it to `HttpServer` and `api_server.dart:220` logged `Connection-level error: <type>` at fine level. Nothing is logged now (finding 6).
- **`stop()` and port release.** `api_server.dart:246-267`: graceful path `await s.close(); await listener?.close();` (`_raw.close()` is awaited, so the port is free when `stop()` returns); force path `s.close(force:true)`, `listener.close()`, `listener.destroyAll()` (destroys every counted open socket). `HttpServer.listenOn` does not close the listener itself, which the patch handles explicitly. Verified: P6, 4 variants (plain/TLS x force/graceful) x 20 restarts on the same port with `preferredPort == maxPortFallback == port` (a still-bound port would throw "No free port"), idle raw sockets and a keep-alive client left open each round: all pass. Gap: sockets still in the TLS handshake are not in `_open`, so `destroyAll` does not close them (X4, finding 4).
- **Accept errors.** `capped_server_socket.dart:25`: `_raw.listen(_onAccept, onError: _out.addError, onDone: _out.close)` forwards listener errors to `HttpServer`, which logs them at `api_server.dart:220` exactly like before. Errors thrown inside `_onAccept` before counting are caught and the socket destroyed (lines 71-75). A socket accepted after `close()` is destroyed (lines 114-117, 136-139).
- **Logging.** `capped_server_socket.dart` has no logger and no `print`; `api_server.dart` gains no log line. No new address is logged. Refusals are silent (finding 6).
- **TLS applied?** `api_server.dart:281-294`: secure profile -> `buildServerContext(identity)` (TLS 1.3 only, same context as before), applied per socket by `SecureSocket.secureServer` (`capped_server_socket.dart:107`), `requestClientCertificate` forced to false for the secure profile (as before: no client cert requested), kept for the legacy plaintext+context profile. Wrapper implements `SecureSocket` so `requestedUri` still says `https` and `http.certificate` still works. X2: with a client certificate requested, wrapper and plain `SecureServerSocket` behave identically (both: client connects, nothing accepted, because dart:io cannot complete such a handshake with an unknown self-signed client cert; so there is no positive control for `peerCertificate` forwarding; it is untouched by any current caller, only the unused legacy path).
- **Other behaviour.** `bind` args equal `HttpServer.bind` (`ServerSocket.bind(address, port)`, no `shared`, no `v6Only`), so port-fallback and "address in use" handling are unchanged (`port_fallback_test` passes). `_TrackedSocket` extends `StreamView` over `_inner.transform(...)`, so pause/resume backpressure reaches the real socket: P5 (4 MiB chunk PUT over TLS, 15 other idle sockets of the same IP, per-IP cap 16) completes in about 110-120 ms.

## 2. Gate table (every row: real exit code)

| gate | command (cwd) | when | rc | result |
|---|---|---|---|---|
| patch | `patch -p1 < patch.diff` (clone root) | 13:52:52 | 0 | clean, no fuzz |
| connection_cap_test x3 | `dart test -j 1 test/security/connection_cap_test.dart` (core) | 14:20:13, 14:20:40, 14:21:08 (+ an earlier run 13:57:05) | 0,0,0 (0) | +12 each time |
| test/security (whole dir) | `dart test -j 1 test/security` | 14:21:35 | 0 | +508 |
| test/integration (whole dir) | `dart test -j 1 test/integration` | 14:23:05 | 0 | +128 ~1 |
| test/conformance (whole dir) | `dart test -j 1 test/conformance` | 14:23:59 | 0 | +389 |
| server unit tests | `api_server_stop_test, api_server_stop_p3_test, port_fallback_test, api_client_test, api_client_tls_test` | 14:24:08 | 0 | +105 |
| p6a-related tests | there is no p6a directory; tests using `p6a_support` sit in test/unit, test/integration, test/security and are covered by the dir runs above and the full core run | | | |
| core full | `dart test -j 1` (packages/libreshare_core) | 14:38:34 - 14:42:08 | 0 | +2619 ~1 (= baseline 2607 + 12, 1 skipped) |
| cli full, first try | `dart test -j 1` (packages/libreshare_cli) | 14:42:08 - 14:43:18 | 1 | +75 +1 failed: `loopback_smoke_secure_test` expects `SAS ` in the script output. NOT caused by R4a: my 13:52 snapshot had the old `tools/loopback_smoke.sh`; the real tree's script changed at 14:03 (adds `--identity-dir` and the SAS check). |
| cli full, after copying the current `tools/loopback_smoke.sh` into the clone | same | 15:07:38 - 15:08:58 | 0 | +77 |
| analyze | `dart analyze --fatal-infos` (clone root) | 14:43:34 | 0 | No issues found |
| format | `dart format --output=none --set-exit-if-changed .` (clone root) | 14:43:39 | 0 | 320 files, 0 changed |
| Flutter imports in core lib | `grep -rnE "import 'package:flutter\|import 'dart:ui\|export 'package:flutter" packages/libreshare_core/lib` | | 1 | none |
| smoke plain 100 MiB | `tools/loopback_smoke.sh 100 53971` | 14:43:18 / 15:09:06 / 15:30:32, 15:30:39 | 0 | byte-identical; 18.9 MiB/s, then 14.6 MiB/s (shared, loaded machine) |
| smoke secure 100 MiB | `tools/loopback_smoke.sh 100 53972 --secure` | 14:43:25 / 15:09:09 | 0 | byte-identical, "SAS codes matched on both sides" (2nd run); 17.5 MiB/s, then 17.0 MiB/s |

Extra smoke runs (15:30, quieter machine): plain 19.0 and 19.1 MiB/s, secure 17.1 MiB/s, all rc 0 and byte-identical. Summary: plain 18.9 / 14.6 / 19.0 / 19.1, secure 17.5 / 17.0 / 17.1 MiB/s against the 18 MiB/s baseline; the single 14.6 run (-19%) happened while other agents were running, the later ones show no throughput loss.

## 3. Mutation table (second copy; each applied alone, restored, `diff -r clone mut` rc 0 every time)

Each mutant was run against the tester's file (12) plus my probes (20). "tester" = reds in `connection_cap_test.dart`; "probe" = reds only in my file.

| mutation | red tests | verdict |
|---|---|---|
| a. remove global cap | tester: global-cap, global-cap-counts-half-sent-requests, slot-release, slot-release-after-refusal, global-cap-applies-across-sources, tls-global-cap (6) | killed |
| b. remove per-IP cap | tester: per-ip-cap, per-ip-cap-protects-others, per-ip-slot-release, tls-per-ip-cap (4); probes P3, P4, P4b, P4c | killed |
| c. never release a slot on close | tester: slot-release, slot-release-after-refusal, per-ip-slot-release (3); probes P3, P4, P4b, P4c | killed |
| d. never release on handshake error | probes only: P3, P4b. **0 of the 12 tester tests** | SURVIVED the tester file (gap), killed by my probes |
| d2. never release on read-side error (`handleError`) | none (32/32 pass) | SURVIVED, equivalent: the error path ends in `HttpServer` calling `destroy()`, which releases; the hook is redundant |
| e. count only after the first request byte (what dart:io does) | tester: global-cap, slot-release, slot-release-after-refusal, per-ip-cap, per-ip-slot-release, global-cap-applies-across-sources, tls-per-ip-cap (>= 7); probes P3, P4 x3 | killed |
| f1. off by one on the global cap (`>` instead of `>=`) | same 6 as (a) | killed |
| f2. off by one on the per-IP cap | tester: per-ip-cap, per-ip-cap-protects-others, per-ip-slot-release, tls-per-ip-cap; probes P3, P4 x3 | killed |
| g. counter leak on the refusal path | tester: per-ip-slot-release only (slot-release-after-refusal uses per-IP 100, so it cannot see a per-IP leak) | killed, thinly (1 test) |
| h. TLS not applied to accepted sockets (plaintext on the secure profile) | tester: tls-per-ip-cap only (via its legitimate TLS client); probes P1, P1b, P2 TLS, X1 TLS, P3, P4b, P5, P6 TLS x2 | killed; the tester file alone has a single test for this. The existing secure suites (test/security, test/conformance) use HTTPS clients and also exercise it (not mutated by me) |
| i. per-IP key = constant | tester: per-ip-cap, per-ip-cap-protects-others, global-cap-applies-across-sources, tls-per-ip-cap, tls-global-cap (5) | killed |
| j. defaults 1000/1000 | tester: default-numbers | killed |

Survivor action: the two survivors are covered by my probes (d) or equivalent (d2). Recommendation: adopt `verifier-tests/connection_cap_verifier_probes_test.dart` (or at least P3, P4b, P1, X3) into the suite.

## 4. Probe results (file: `verifier-tests/connection_cap_verifier_probes_test.dart`, 20 tests; run in mut on the unmutated patch: 19 pass, 1 fails = X3 as expected)

| probe | result |
|---|---|
| P1 PinGuard keyed by real source (TLS, real PinGuard) | PASS. 5 wrong PINs from 127.0.0.2 -> 401 x5, then correct PIN from 127.0.0.2 -> 403 BLOCKED; the same correct PIN from 127.0.0.3 and 127.0.0.1 -> 202. P1b: 4+4 strikes from two sources block nobody (no shared key). |
| P2 rate limiter separates IPs | PASS (TLS and plain): 12 POST /sessions from 127.0.0.2 -> exactly 2x 429; 127.0.0.3 and 127.0.0.1 not limited. |
| X1 handler sees the true source | PASS (TLS 127.0.0.4, plain 127.0.0.5). |
| P3 100 abandoned handshakes (5 shapes: immediate close, 5-byte record header, real ClientHello cut at random, HTTP on TLS port, 2 bytes + FIN) | PASS: all 16 per-IP slots usable after 0.46 s; a following HTTPS GET /info = 200. P3b (100 abandoned from 40 source IPs, global 20): PASS. |
| P4 100 connect/close cycles | PASS (plain: close / full request / garbage / half head; TLS: 100 full handshakes; 30 server-side `Connection: close`): counters back to zero, port serves 200 afterwards. |
| P5 4 MiB chunk PUT over TLS with 15 idle same-IP sockets | PASS, 200, 4 MiB received, ~110-120 ms. |
| P6 stop() then start() x20, same port | PASS for plain/TLS x force/graceful (4 x 20 restarts). |
| X2 client certificate parity | PASS (identical to `SecureServerSocket`, see section 1). |
| **X3 half-closed (FIN) requests vs per-IP cap 2** | **FAIL on the patch**: 10 half-closed long-poll requests (`GET /sessions/x?wait=20`, FIN right after the request) -> all 10 reached the handler although the per-IP cap is 2. With fix A below: 2. |
| X4 stop(force) with a socket stalled in the TLS handshake | characterisation: that socket is NOT closed by `stop(force: true)` (3 s). |
| X5 stalled TLS handshake | characterisation: after 6 s the slots are still held (no handshake timeout). |

## 5. Findings

1. **MEDIUM - half-closed sockets escape the cap.** `capped_server_socket.dart:169-176`: the stream transform calls `_onClosed()` when the READ side ends (`handleDone`) or errors. A client that sends a request and then shuts down its write side (FIN) is released from the count while the server still holds the socket and runs the handler (long-poll up to 25 s, or an upload being verified). One IP can therefore have far more than 16 requests in flight. (Probe X3.) Exploit needs a request that blocks in the handler, which on the secure profile needs authentication, so it is bounded, but it defeats the stated per-IP guarantee. **Fix (validated):** delete the `_onClosed();` line in `handleError` and the one in `handleDone` and rely on `destroy()`/`close()` (dart:io's `HttpServer` always calls one of them when the connection ends). Result of that experiment (mutation `fixA`): tester 12/12 + probes 20/20 pass, X3 gives 2, slot-release and P3/P4 still pass. If a leak shows up on a platform, add a safety `Timer` after read-side done instead of an immediate release.
2. **MEDIUM - no TLS handshake timeout.** `capped_server_socket.dart:107`: `SecureSocket.secureServer(...)` has no timeout, so a client that connects and stalls holds a slot (and an fd) until it closes it (X5: still held after 6 s). After the handshake, dart:io's `HttpServer` idle timer (120 s, SDK `http_impl.dart:3509`/`3540`) reaps silent sockets, but nothing reaps the handshake stage. Result: the cap bounds the damage (16 per IP, 64 total) but 4 attacker IPs, or one attacker behind a shared NAT/hotspot IP of the victims, can keep all slots forever. Not a regression (before there was no limit at all). **Fix:** `SecureSocket.secureServer(...).timeout(const Duration(seconds: 10))` with the existing `onError` path (destroy + release); add a test with a 1 s test knob or a fake delay.
3. **LOW - test gaps in the tester file** (covered by my probes): mutation d survives all 12 tests (handshake-error release); mutation g is caught by one test only; mutation h (plaintext on TLS) by one test only. **Fix:** add P3/P4b/P1 style tests to the suite.
4. **LOW - `stop(force: true)` leaves sockets that are mid-handshake open** (X4): `destroyAll()` only knows `_open`. **Fix:** keep a `Set<Socket> _handshakingSockets`, destroy them in `destroyAll()` (they then error out of `secureServer` and release).
5. **LOW - theoretical hang:** `close()` does `await _out.close()` on a controller; if nothing ever listened (the `listenOn` failure path in `api_server.dart:212-217`) the future can stay pending. Not reproducible today (`listenOn` does not throw, `server.listen` follows immediately; P6 80 restarts fine). **Fix:** `unawaited(_out.close())`.
6. **LOW - refusals and handshake failures are silent.** No log or counter, so an operator cannot tell a slow-loris from a flaky client. **Fix:** `_log.fine('connection refused: limit')` with NO address (keeps the "no new addresses logged" property) and a refusal counter on `CappedServerSocket` for the UI/CLI.
7. **INFO - NAT/hotspot:** all clients behind one IP share 16 slots; fine for a multi-file Android send (about 5 sockets) but several phones behind one NAT can starve each other. Defaults 64/16 are a user decision (see `report.md`).
8. **INFO - snapshot drift:** the real tree changed `tools/loopback_smoke.sh` after the patch snapshot (14:03); the orchestrator should re-run the CLI suite after applying, as `apply-notes.md` already says. No other file differs between the real tree and the clone (checked with `diff -rq`, excluding the patched files).

## 6. Files
- `verifier-tests/connection_cap_verifier_probes_test.dart` (formatted; imports `package:libreshare_core/src/server/capped_server_socket.dart` for X2; helpers from `test/helpers/`)
- `verifier-tests/run-summary.txt` (stamped command log)
- Logs: `.toolchain/scratch/e5-r4a-verify/logs/` (`mut-<id>.log`, `probes-run*.log`, `core-full.log`, `cli-full*.log`, `smoke-*.log`)
