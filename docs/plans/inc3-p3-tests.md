# Inc 3 / P3 tests (secure ApiServer + PIN guard) - tester hand-over

Written by the P3 tester, 2026-11-05. Sources: LSP-1.md 0.3, 4.1, 4.3.1-4.3.6, 5.2, 5.4; inc3.md D5/D11; inc3-seams.md. No file under `lib/` was meant to be touched (see "Incident" at the end).

## Files (all under packages/libreshare_core/test/)

| File | Group summary |
|---|---|
| `helpers/p3_secure_handler.dart` | `P3SecureHandler implements SecureTransferHandler`: records `P3Call(method, peer, remoteAddress, ...)`, hooks `onCreateAuthenticated/onRevealSas/onPair/onGetSession/onPutChunk`, `failWith` throws an `LsException`. Plain `createSession` is recorded separately (must stay 0 in the secure profile). |
| `helpers/p3_secure_rig.dart` | `P3Rig.start(secure:, contactsOnly:, enableRateLimit:, rateLimiter:, onRegister:)` real `ApiServer` on loopback; `rig.request(..., signAs:/authHeader:/chunked:/from:)` raw `HttpClient` (from = other loopback source IP, TLS included); `rig.proof(...)` bends any proof field; `P3Raw` raw TLS/TCP socket; `P3LogCapture`; `P3Clock`; identities `p3Alice/p3Bob/p3Mallory/p3ServerKey/p3OtherServerKey`. |
| `security/pin_test.dart` (40) | policy off/fixed/window; PIN format; PIN_REQUIRED never a strike; wrong/expired/consumed answer identically; TTL +-1 ms; per-IP 4/5 and 10 min +-1 ms; sliding window; per-IP isolation; global 24/25, lock 10 min, rotation, `onBruteForce` once per trigger; rotate(); oneTime/consume; exempt; success never a strike; no PIN in logs/exceptions/toString (with log-capture twin). |
| `security/token_test.dart` (48) | valid proof + peer; request binding (path, method, body hash, flipped byte, other server, query, percent-encoding as sent); window +-130 s fails / +-110 s passes; replay (same connection, new connection, failed proof does not burn nonce, two clients same nonce); 18 malformed header shapes; dup header; forged cert/sig mix; generic answer (identical bytes and headers for 10 failure kinds, no check named); the four proof routes; junk header ignored on proof-less routes. |
| `security/contacts_only_server_test.dart` (19) | stranger vs contact on GET /info, /register, /sessions: 404 identical to unknown route (status, bytes, header names and values but Date); blocked / key-changed are strangers; gate before body (5 MiB) and before rate limit; known+trusted served; removal and block mid-run; toggle per request; /pair exempt; session/file routes ungated. |
| `security/rate_limit_test.dart` (10) | 10/min, 11th 429 + Retry-After; refill with injected clock; per IP (127.0.0.2); only POST /sessions; limit before auth and before body read; /pair shares the bucket; plaintext twin. |
| `security/oversize_test.dart` (22) | 256 KiB / +1 / 4 MiB / +1 on POST /sessions; 10,000 files; size before auth; other routes 256 KiB; chunked rules; Content-Length absurd; 2 concurrent oversize bodies (3rd = 429), slot release, per-server; plaintext profile unchanged. |
| `conformance/api_conformance_secure_test.dart` (40) | ArgumentError; certificate = identity; plaintext client gets close and no HTTP bytes; TLS 1.2 refused (skips without openssl); Date on 10 response kinds; check order (auth<shape<version<consistency, sasCommit shape); chunk-hash rule both profiles; /sas and /pair delegation with peer; plaintext 404 for /sas and /pair; /register; routing; log hygiene; stop() semantics over TLS. |
| `unit/api_server_stop_p3_test.dart` (8, PASS today) | Characterises current stop()/start(). `unit/api_server_stop_test.dart` already existed and is untouched; this is a new file with the cases it lacks (never started, twice, concurrent, in-flight completes, force, restart). |

## New symbols (not in the tree; tests fail to compile on them)

```dart
// lib/src/security/pin_guard.dart  (tests import it directly, not through the barrel)
class PinGuard implements PinVerifier {
  PinGuard({PinPolicy policy = const PinPolicy.off(), String? pin, Duration? pinTtl,
            Clock clock = const SystemClock(), void Function()? onBruteForce});
  String? get currentPin;   // null when the policy is off
  void rotate();            // fresh random 6-digit PIN, different from the old, TTL restarts
}
```
`pin` null with fixed/window policy = generate; a malformed `pin` throws (any type, message without the PIN). `pinTtl` is new (D5 "optional TTL"); the orchestrator may rename it. Everything else uses existing API (`ApiServer(security:, contactsOnly:, rateLimiter:, onRegister:)`).

## Red state (before any P3 code; `dart test <file>` exit 1 each)

| File | tests | failing | reason |
|---|---|---|---|
| pin_test | 40 | 40 | compile error: `pin_guard.dart` / `PinGuard` undefined |
| token_test | 48 | 48 | `HandshakeException` (server still plain HTTP) |
| contacts_only_server_test | 19 | 19 | `HandshakeException` |
| rate_limit_test | 10 | 9 | `HandshakeException`; 1 plaintext twin passes |
| oversize_test | 22 | 19 | `HandshakeException`; 3 plaintext twins pass |
| api_conformance_secure_test | 40 | 32 | 29 `HandshakeException`, no ArgumentError, plaintext client still answered, handler called; 8 plaintext twins pass |
| api_server_stop_p3_test | 8 | 0 | characterisation, green today |

## Green check

A throw-away reference implementation (written by me in a scratch copy, NOT meant for the repo) made all 40+48+19+10+22+40 tests pass once. It also served for the mutation table below. The 3x flake runs were NOT done (the incident below stopped me); the verifier must do them. The tests found two gaps in that first draft (no `Retry-After` on the oversize 429, percent-encoded path normalisation by `Uri`).

## Mutation checks for the verifier (each must turn red; result with the scratch reference)

| Mutation | Expected red | Seen |
|---|---|---|
| nonce cache never written (`nonces: NonceCache()` per call) | token_test replay x2 + conformance | 3 failing |
| stranger answered 403/other instead of 404 | contacts_only_server_test | 9 |
| `contactsOnly()` evaluated once | contacts_only_server_test toggle | 1 |
| Content-Length ignored (chunked up to 4 MiB) | oversize_test chunked | 2 |
| oversize cap 3 / slot never released / 256 KiB cap for /sessions | oversize_test | 4 / 2 / 10 |
| auth before rate limit | rate_limit_test | 2 |
| /pair not in the shared bucket | rate_limit_test | 2 |
| plain `createSession` called in secure profile | conformance + token | 8 |
| `/register` fingerprint vs proof not compared | token_test | 1 |
| X-LS-Chunk-SHA256 not required (secure) / required (plaintext) | conformance | 1 / 1 |
| `ownFingerprint` not the server's own | token_test | 14 |
| PIN strike counted on success | pin_test | 2 |
| lock without rotation / threshold 6 / 26 / block 9 min | pin_test | 4 / 8 / 6 / 1 |
| PIN-less request counted as a strike; exempt counted | pin_test | 1 / 1 |
| expired PIN answered with another message; PIN in message; oneTime never consumed | pin_test | 1 / 2 / 3 |
| `Date` header removed | NOT detectable by mutation: `shelf_io` adds `Date` itself; the tests still guard it | 0 |

## SPEC-GAPs (safer reading chosen)

1. Answer to the 5th wrong PIN: `PIN_INVALID` or `BLOCKED` both accepted; the next request must be `BLOCKED`.
2. A PIN-less request from a blocked IP gets `BLOCKED` (block wins over `PIN_REQUIRED`).
3. Not asserted: whether `rotate()` clears strikes, `currentPin` after `consume()`, exempt vs an active block, whether refused attempts extend a block.
4. `onBruteForce` that throws must not escape `check()` (robustness, not in the spec).
5. A fixed PIN that is not 6 digits is refused at construction.
6. More than 10,000 files: spec puts the 413 in the size step, but today only the handler checks it; the server tests assert only that 10,000 pass.
7. `X-LS-Auth` on routes that do not use it is "not used" = ignored (junk header still served).
8. The 400 for a `/sas` nonce that is not 22 base64url characters is asserted at the HTTP layer (fake handler cannot produce it).
9. `/pair`: `sender.fingerprint == proof` (4.3.4) not asserted (server or handler); the rate-limit bucket sharing is.
10. "Oversize" = POST /sessions with declared Content-Length above 256 KiB; the cap of 2 is per server, not per IP; the 429 carries `Retry-After` (4.3.1 says any 429).
11. Duplicate `X-LS-Auth` headers are refused (grammar says "present once").
12. `ArgumentError` for a non-secure handler may come from the constructor or `start()`.
13. Unauthenticated `POST /sessions` requests consume rate-limit tokens (limit runs before auth).

## Incident (my fault, repaired only in part)

While running mutation checks, a path mix-up (another agent replaced my scratch `ref/` directory, my script then used relative `lib/` paths) wrote my scratch reference `api_server.dart` over `packages/libreshare_core/lib/src/server/api_server.dart` and created `lib/src/security/pin_guard.dart`. Restoring was denied by the permission system, so the tree still contains them. Pristine original: `.../scratchpad/ws/packages/libreshare_core/lib/src/server/api_server.dart` (byte-identical to `.../scratchpad/ref/libreshare_core/...`); `pin_guard.dart` did not exist before and must be deleted. Until restored, the red-state numbers above cannot be reproduced.

**Resolved by the orchestrator, 2026-11-05 04:29 IST:** `api_server.dart` restored from the pristine copy (verified with `cmp`), `pin_guard.dart` deleted, no other `lib/` file had changed. Red state re-measured against the restored tree: pin_test load failure (PinGuard undefined), token 0/48 pass, contacts_only_server 0/19, rate_limit 1/10, oversize 3/22, conformance_secure 8/40, stop_p3 8/8 pass: identical to the table. The scratch reference implementation is kept outside the repo (`scratchpad/orch/`) and handed to the P3 coder as untrusted input. Reviewer extras: (a) slow-body starvation of the 2 oversize slots (SPEC-GAP 10) needs a body read timeout; (b) SPEC-GAP 6 (more than 10,000 files => 413) is P4's check in the receiver.
