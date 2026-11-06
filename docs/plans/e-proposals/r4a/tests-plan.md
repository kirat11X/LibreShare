# R4a tests-plan (tester, 2026-11-06 10:33)

Clone: `.toolchain/scratch/e5-r4a/clone` (new file only: `packages/libreshare_core/test/security/connection_cap_test.dart`; copy in this folder).
Behavioural-red check copy: `.toolchain/scratch/e5-r4a/stubcheck` (same clone + a throwaway edit of `api_server.dart` that only adds the two fields and ignores them; NOT a deliverable).

## Knobs chosen (coder implements; may rename only together with the test)
`ApiServer({... int maxConnections = 64, int maxConnectionsPerIp = 16})`, public final fields of the same names.
Counted per accepted TCP connection from accept (before request bytes / TLS handshake) to close. dart:io `HttpServer` reports a connection only after the request head is parsed, so the count must sit at socket level (e.g. a `ServerSocket`/`SecureServerSocket` wrapper given to `HttpServer.listenOn`, or equivalent). Over a limit: new connection closed at once (503 first optional). Applies to plain and TLS profile. Slot freed on close.

## Tests (each description starts with "GUARD <name>")
| test | guard targeted |
|---|---|
| default-numbers | defaults 64 / 16 are pinned (and per-IP >= 8, total >= per-IP) |
| global-cap | the (N+1)th idle socket is closed/refused, first N untouched |
| global-cap-counts-half-sent-requests | slow-loris half-sent heads are counted too |
| global-cap-leaves-room | with N-1 idle sockets held, GET /info + POST /sessions + PUT chunk over one keep-alive socket (total exactly N) succeed (control: a too-aggressive cap fails it) |
| slot-release | closing a held socket frees a slot; a new client is served within 2 s |
| slot-release-after-refusal | 20 refused attempts + 3 closes leave all 3 slots free (no counter leak on the refusal path) |
| per-ip-cap | 127.0.0.2 gets only perIp sockets; 127.0.0.3 and 127.0.0.1 still served |
| per-ip-cap-protects-others | attacker with 12 slow-loris attempts keeps exactly 3 sockets; a legit client under the global cap is served |
| per-ip-slot-release | per-IP counter decrements on close |
| global-cap-applies-across-sources | N held by several IPs: the (N+1)th from a fresh IP is closed |
| tls-per-ip-cap / tls-global-cap | same limits on the TLS profile with handshake-less sockets |

## Commands and results
1. `cd clone/packages/libreshare_core && flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/security/connection_cap_test.dart` -> rc=1, 2026-11-06 10:30:35. Compile error: `maxConnections` / `maxConnectionsPerIp` not defined for ApiServer (whole file red, expected).
2. Same command in `stubcheck` (fields added, ignored) -> rc=1, 2026-11-06 10:32:52: `+2 -10`. The 10 behavioural tests fail with "Expected: true Actual: false" (extra connection not closed) / "Expected 3, Actual 12"; the two controls (default-numbers, global-cap-leaves-room) pass, as they must on an unlimited server.
