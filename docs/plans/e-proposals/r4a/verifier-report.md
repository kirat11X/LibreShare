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

---

# Round 2 (re-verification of the coder's fixes; 2026-11-06 21:00-21:57)

Scratch: `.toolchain/scratch/e5-r4a-verify2/` (fresh `clone` of the CURRENT real tree + `patch -p1 < patch.diff` (416 lines): rc 0, no .rej/.orig; tester file copied, byte-identical to round 1; `mut` = second copy). Real tree and `lib/` untouched; tester file untouched. Every run alone under `flock -o /tmp/libreshare-heavy.lock`, `TMPDIR=$REPO/.toolchain/tmp`. Logs: `.toolchain/scratch/e5-r4a-verify2/logs/`; stamped summary: `verifier-tests/run-summary-round2.txt`.

## Round 2 verdict: SAFE AFTER FIXES (finding 1 is fixed; finding 2 is only half fixed and the other half is a real defect)

- **Finding 1 (half-close bypass): FIXED.** X3 now shows 2 of 10 half-closed long-polls reach the handler with per-IP cap 2. Restoring the old read-side release (mutation `halfclose`) turns X3 red.
- **Finding 2 (TLS handshake timeout): the slot accounting is fixed, the connection is NOT closed.** After the 10 s timeout the counter is decremented, but the TCP connection stays open (client never sees EOF; 0 of 24 stalled connections closed, X8). The cap therefore under-counts real sockets: an attacker can keep stalling handshakes at 16 per IP per timeout period and the server keeps all those fds. This is worse than round 1 for this stage (round 1 held the slot, a hard bound) although still no worse than the pre-patch tree (no cap at all). Not a plaintext, address or other regression.
- Why (X4 answer): `SecureSocket.secureServer(socket, ...)` detaches the descriptor from the `Socket` object (`socket._detachRaw()`, SDK `secure_socket.dart:205`). After that, `socket.destroy()` and `socket.close()` are no-ops for the TCP connection. Experiment E1 (`verifier-tests/exp_detach_experiment.dart.txt`, log `exp-detach-round2.log`): destroy() or close() 1 s after `secureServer` took over, client saw close within 4 s: **false** (both); handshake future stays pending; untouched stalled handshake: no close within 12 s (E6). E5 (RawServerSocket + `RawSecureSocket.secureServer(raw)`, `raw.close()` after 1 s): client saw close: **true**. So the lib is wrong (not only the probe): both the 10 s timeout (`capped_server_socket.dart` `fail()`, the `Timer(_handshakeTimeout, fail)` path) and `destroyAll()`'s `_pending` loop call `destroy()` on the detached socket, which does nothing.

## Round 2 gate table

| gate | command (cwd = clone/packages/libreshare_core) | when | rc | result |
|---|---|---|---|---|
| patch | `patch -p1 < patch.diff` (clone root) | 21:00:47 | 0 | clean |
| tester file x3 | `dart test -j 1 test/security/connection_cap_test.dart` | 21:07:20, 21:07:52, 21:08:20 | 0,0,0 | +12 each |
| my probes, updated (24 tests: the 20 of round 1 with X4/X5 turned into assertions + X5b, X6, X7, X8) on the coder's patch | `dart test -j 1 -r expanded test/security/connection_cap_verifier_probes_test.dart` | 21:15:41 | 1 | +21 -3; red: X4, X5b, X8 (all "the stalled TCP connection is not closed") |
| same, only the new/changed tests as a standalone file `connection_cap_verifier_round2_test.dart` (6 tests) | `dart test -j 1 -r expanded test/security/connection_cap_verifier_round2_test.dart` | 21:54:49 | 1 | +3 -3; red: X4, X5b, X8 |
| experiments | `zz_exp_detach_test.dart` (E1/E5/E6), `zz_exp_gate_test.dart` (E7) | 21:08:47, 21:18:17 | 0 | E1/E6 show the no-op; E5 and E7 show what works |
| analyze | `dart analyze --fatal-infos lib/src/server test/security/connection_cap_test.dart test/security/connection_cap_verifier_probes_test.dart test/security/connection_cap_verifier_round2_test.dart` | 21:56:19 | 0 | No issues found |
| format | `dart format --output=none --set-exit-if-changed` on api_server.dart, capped_server_socket.dart and the three test files | 21:56:20 | 0 | 5 files, 0 changed |

Full core/CLI suites skipped as instructed (the orchestrator gates).

## Round 2 probe results (updated expectations)

- X3 (half-close vs per-IP cap 2): PASS, 2 of 10 reach the handler.
- X5 (default 10 s timeout): the slots are still held at 5 s and free at about 12.5 s: PASS. The probe wait was adjusted from 6 s to "check at 5 s (held) and 12.5 s (free)", and the test turned from characterisation into an assertion.
- X6 (timeout knob 1 s: slots free within 3 s) PASS; X7 (knob 1 s does not hurt 10+1 normal HTTPS requests) PASS.
- **X4 FAIL**, **X5b FAIL**, **X8 FAIL** (see verdict): `stop(force: true)` does not close a socket stalled in the handshake; a 1 s timeout does not close the stalled connection; of 24 stalled connections the server closed 0.
- X4 is therefore not a probe error: with the coder's code a handshaking socket is NOT destroyed by `stop(force)`, nor by the timeout.

## Round 2 mutation table (tester 12 + my 24 probes, each alone, restored, `diff -r clone mut` rc 0 each time)

| mutation | red tests | verdict |
|---|---|---|
| `halfclose`: restore the read-side `_onClosed()` in handleDone/handleError (finding 1 fix removed) | X3 (plus the already-red X4, X5b, X8); none of the 12 tester tests | killed, by X3 only |
| `notimeout`: handshake timer set to 1 day (finding 2 fix removed) | X5, X6 (plus X4, X5b); none of the 12 tester tests | killed, by X5/X6 only |
| `timeoutleak`: timeout destroys but does not release the slot | P3, P4b, X5, X6 (plus X4, X5b) | killed |

Note: the tester's 12 tests contain no half-close and no handshake-timeout test; the two fixes are protected only by my probe files. They should be adopted into the suite (see below).

## Concrete lib fix for the open defect (validated in the scratch copy only)

Diff: `verifier-tests/fix-proposal-r2-handshake-gate.diff` (95 lines against the coder's `capped_server_socket.dart`; full file `logs/capped_server_socket.with-gate-fix.dart` in the scratch dir). Idea (experiment E7: `zz_exp_gate_test.dart` passes): phase 1, while the socket is still a plain `Socket` that CAN be destroyed, wait with a timer for one whole first TLS record (5-byte header + length, at most 16640 bytes, first byte 0x16), pausing the subscription afterwards; on timeout, close, error or a non-TLS first byte, `socket.destroy()` and release the slot (a real close, E7b). Phase 2: hand the data to `SecureSocket.secureServer(socket, ctx, bufferedData: record)`; this cannot be aborted any more, so the slot stays counted until it succeeds or fails (honest accounting, bounded fds). `destroyAll()` then closes handshake-stage sockets that are still in phase 1.
Result in `mut` with this change: tester 12 + probes 24 + round2 file 6 = **+42 all passed, rc 0** (21:53:11-21:54:49), X4 true, X5b true, X8 24 of 24 closed, X3 still 2. `dart analyze` on it had one warning only in my test file (unused `_pin`, since removed). Limit: a client that sends a complete ClientHello and then stalls before its Finished message is still not abortable in phase 2 (Dart offers no handle); it keeps its slot (bounded by the caps, never uncounted). I did not test that case. If the orchestrator prefers a smaller change: drop `release()` from the timeout path (keep the slot until the handshake future settles); that restores the round 1 bound, but then the timeout does nothing useful.

## Round 2 findings

1. **MEDIUM (open): handshake timeout does not close the connection** (X4, X5b, X8, E1). Fix: the gate above (validated), or at minimum do not release the slot on timeout.
2. **LOW (open): test coverage of the two fixes lives only in my probe files.** Adopt `verifier-tests/connection_cap_verifier_probes_test.dart` (round-1 file, 20 tests, X4/X5 there are only characterisations) plus `verifier-tests/connection_cap_verifier_round2_test.dart` (6 tests: X4, X5, X5b, X6, X7, X8; X4/X5b/X8 are red until finding 1 is fixed) into `test/security/`. Note the round-2 file supersedes X4/X5 of the round-1 file: if both are adopted, delete the old X4/X5 to avoid duplicates (the old X4 only prints).
3. **INFO: apply-notes.md says the round-1 probe file is "green with this patch"** - true for that file (its X4/X5 only print), but the round-2 file is not.

---

# Round 3 (re-verification of the gated handshake; 2026-11-07 15:06-15:36)

Scratch: `.toolchain/scratch/e5-r4a-verify4/` (clone, `mut` for mutations, `mut2` for the fix experiment). Fresh clone of the CURRENT real tree (rsync with `--exclude=.toolchain --exclude=dist --exclude=build --exclude=.dart_tool --exclude=.git --exclude='scratch_*' --exclude='test_c_*' --exclude='/test_*.dart'`; it already contains R4b, R4c, R4e, R1c/R1d), `grep -c '^--- ' patch.diff` = 2, `patch -p1 < patch.diff` rc 0, no .rej/.orig. Tester file copied unchanged (byte-identical to round 1/2). No lib/ edit, no tester edit, real tree untouched. Every run alone under `flock -o /tmp/libreshare-heavy.lock`, `TMPDIR=$REPO/.toolchain/tmp`. Logs: `e5-r4a-verify4/logs/`; stamped summary: `verifier-tests/run-summary-round3.txt`.

## Round 3 verdict: SAFE AFTER FIXES (one small, validated fix; otherwise good)

What is now right: half-close bypass fixed (X3 = 2 of 10), handshake timeout really closes the connection (X4, X5b, X8 green: 24 of 24 stalled connections closed), the new gate drops silent, slow, oversize, lying-length and non-TLS first-byte clients, real pinned `ApiClient` works with 100 ms latency and with the ClientHello trickled byte by byte, and the cap stays honest (never under-counts).

What is still wrong (MEDIUM, new finding): the gate only checks the record FRAMING, not that the record is a ClientHello. A 5-byte record header with length 0 (R2b) or a 9-byte message "record length 4 + ClientHello header claiming 500 bytes" (R2d) passes phase 1; `secureServer` then waits for more bytes forever, and that phase cannot be aborted, so the slot is held until the client closes (R2b and R2d: server did not close within 3 s). The gate therefore stops only lazy attackers; a 9-byte message holds a slot permanently (same bound as round 1, no better). Fix (validated, below): require the first record to hold exactly one whole ClientHello. Residual after the fix: an attacker who replays a REAL ClientHello and then stalls (R5) still holds its slot; that is unavoidable with dart:io (no handle to abort the detached descriptor) but is bounded and counted (see "How many can an attacker hold").

## Round 3 gate table (core package unless noted)

| gate | command | when | rc | result |
|---|---|---|---|---|
| patch | `patch -p1 < patch.diff` (clone root) | 15:06:58 | 0 | clean; `grep -c '^--- '` = 2 |
| tester file x3 | `dart test -j 1 test/security/connection_cap_test.dart` | 15:12:16, 15:12:49, 15:13:15 | 0,0,0 | +12 each |
| ALL verifier files on the coder's patch | `dart test -j 1 -r expanded` on `connection_cap_verifier_probes_test.dart` (18), `..._round2_test.dart` (6), `..._round3_test.dart` (13) | 15:13:43 | 1 | +35 -2 (37 tests); red: R2b, R2d only |
| same + tester, with the ClientHello check (mut2) | tester 12 + 37 | 15:14:45 | 0 | **+49 all passed** |
| analyze | `dart analyze --fatal-infos lib/src/server` + the tester file + the three verifier files | 15:16:15 | 0 | No issues found |
| format | `dart format --output=none --set-exit-if-changed` on api_server.dart, capped_server_socket.dart, tester file, three verifier files | 15:16:15 | 0 | 6 files, 0 changed |
| analyze of the fixed lib | `dart analyze --fatal-infos lib/src/server` in mut2 | 15:16:15 | 0 | No issues found |

Full suites skipped as instructed.

## Round 3 mutation table (tester 12 + 37 verifier tests; each applied alone, restored, `diff -r clone mut` rc 0 every time; R2b/R2d are red in the baseline too and are listed only when they are the sole detector)

| mutation | red tests (besides R2b/R2d) | verdict |
|---|---|---|
| `halfclose`: restore the read-side release | X3 | killed (X3 only; none of the 12 tester tests) |
| `notimeout`: first-record timer = 1 day | X5, X5b, X6, R1, R4 | killed |
| `timeoutleak`: `fail()` destroys but does not release | P3, P4b, X5, X6, R1, R2a, R2c, R4, R8 | killed |
| `skipwhole`: stop waiting for the whole record (gate completes after 5 bytes) | X4, X5, X5b, X6, R1, R7 | killed |
| `nobuffered`: drop `bufferedData: record` | tester `tls-per-ip-cap`; P1, P1b, P2, P3, P4b, P5, P6 x2, X1, X2, X7, R2c, R3, R5, R6 (all TLS clients fail) | killed |
| `releasebefore`: release the slot before the handshake settles | R5 | killed (R5 only) |
| `nontls`: non-TLS first byte not destroyed at once | R8 | killed (R8 only) |
| `nolen`: no 16640 length bound | R2a | killed (R2a only) |
| `nopending`: `destroyAll` skips handshaking sockets | X4, R7 | killed |

Note: only `nobuffered` is also caught by a tester test; the other new guards are protected by the verifier files alone, so they must be adopted.

## Break attempts (file `connection_cap_verifier_round3_test.dart`, 13 tests; "on patch" = coder's code; "with fix" = ClientHello check)

| attack | result |
|---|---|
| R1 trickle one byte per 400 ms after a 512-byte record header (timeout 2 s) | closed at 2.0 s, slot freed (timeout is TOTAL, not per byte) |
| R2a record length 0xFFFF (lie / oversize) | closed in 0.5 ms |
| R2b record length 0 | **on patch: not closed (slot held)**; with fix: closed in 0.4 ms |
| R2c full 16640-byte garbage record | closed in 2 ms, slot freed |
| R2d complete 9-byte message claiming a 500-byte ClientHello | **on patch: not closed (slot held)**; with fix: closed in 0.3 ms |
| R3 real ApiClient, ClientHello trickled in 1-byte packets (600 bytes through a proxy) | works |
| R4 connect and send nothing | closed at 1.5 s (the timeout), slot freed |
| R5 complete real ClientHello, then silence (4 attackers, per-IP cap 4, timeout 1 s) | not closed (cannot be), but counted: direct attempts from the same IP are refused at 0.3 s AND at 3.3 s |
| R6a/b/c real pinned `ApiClient.info()` direct / 100 ms latency per direction (about 520 ms) / 100 ms latency with a 1.5 s timeout x3 | all work |
| R7 `stop(force: true)` with a phase-1 and two phase-2 stalled sockets | returns in 0 ms; phase-1 client closed after 0.3 s; the port is reused immediately; phase-2 sockets cannot be closed by stop (no handle), they die when the client or process ends |
| R8 plain HTTP on the TLS port | closed in 0.7 ms |

### How many stalled-after-ClientHello sockets can an attacker hold? Bounded by the caps, never uncounted
`maxConnectionsPerIp` (16) per source address, `maxConnections` (64) in total, until the client gives up (there is no phase-2 timeout and none is possible). So 4 source addresses, or one address that is shared with the victims (NAT, hotspot), can occupy every slot of a TLS listener until they disconnect. That is the same hard bound as round 1, no worse; R5 proves the counter stays honest (the `releasebefore` mutation, which makes it dishonest, turns R5 red). If this matters, the only real cure is to do the handshake on a `RawSecureSocket` (a handle that `close()` aborts, experiment E5 of round 2) and wrap the result in an own `Socket` adapter: a larger change, not recommended for this patch.

## Concrete fix (validated)

`verifier-tests/fix-proposal-r3-clienthello-check.diff` (17 lines against the coder's `capped_server_socket.dart`, only inside `_readFirstRecord`): reject the record when its length is below 4 or above 16640, and, once 9 bytes are in, when the handshake type is not 1 (ClientHello) or the 3-byte handshake length is not exactly record length - 4. Real clients (checked: the real `ApiClient`, `dart:io` `HttpClient`, the 1-byte-trickled and 100 ms-latency variants) send one whole ClientHello in the first record, so nothing legitimate is dropped; tester 12 + 37 verifier tests = 49 all green. (A ClientHello split over several records, legal but unused in practice, would be refused.) The coder may instead document the limitation, but then R2b and R2d must not be adopted red.

## Verifier test files to apply (exact list; copy to `packages/libreshare_core/test/security/`)

All three are formatted, analyze-clean under `--fatal-infos`, with no `dart:mirrors`, and in `docs/plans/e-proposals/r4a/verifier-tests/`:
1. `connection_cap_verifier_probes_test.dart` (CONSOLIDATED, 18 tests: P1, P1b, P2 x2, X1, X1b, P3, P3b, P4, P4b, P4c, P5, P6 x4, X2, X3). The round-1 print-only X4/X5 were removed from it; the original is kept as `connection_cap_verifier_probes_test.round1-original.dart.txt` (not a test).
2. `connection_cap_verifier_round2_test.dart` (6 tests: X4, X5, X5b, X6, X7, X8; unchanged since round 2).
3. `connection_cap_verifier_round3_test.dart` (13 tests: R1, R2a-d, R4, R8, R3, R6a-c, R5, R7). R2b and R2d are red unless the ClientHello-check fix is applied (they pass with it).
Plus the tester's `connection_cap_test.dart`. Nothing is duplicated between the three verifier files (the old X4/X5 characterisations exist only in the `.txt`). Runtime of all verifier files together: about 60 seconds; X5 alone needs 12.5 s (it checks the default 10 s timeout).

## Round 3 findings
1. **MEDIUM (open): gate checks framing only** (R2b, R2d): a 5-9 byte message holds a slot forever. Fix: `fix-proposal-r3-clienthello-check.diff` (validated).
2. **INFO (accepted limit):** stalled-after-valid-ClientHello sockets hold their slots (bounded 16/IP, 64 total); cannot be fixed without a RawSecureSocket adapter.
3. **LOW:** `stop(force)` cannot close phase-2 sockets (same root cause); harmless for process exit and port reuse (R7).
4. **INFO:** only `nobuffered` is caught by the tester file; keep the verifier files in the suite.
