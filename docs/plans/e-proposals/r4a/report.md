# R4a report (coder)
Clone: .toolchain/scratch/e5-r4a/clone. Files: new lib/src/server/capped_server_socket.dart, edit lib/src/server/api_server.dart (patch.diff). No test, pubspec or dependency touched.

## Design
`CappedServerSocket` (implements ServerSocket) binds the raw ServerSocket, counts per accepted TCP connection (total and per remote IP) from accept to close, destroys the new socket at once when over a limit (no counter touched on refusal). `HttpServer.listenOn` serves it. TLS: each accepted socket gets `SecureSocket.secureServer` inside the wrapper, so the slot is held during the handshake (handshake-less sockets count); handshake failure frees the slot. Sockets are wrapped (`_TrackedSocket` / `_TrackedSecureSocket`) because `Socket.done` stays pending after peer close or destroy (checked); the release is taken from stream done/error, destroy and close, once only. `ApiServer.stop` closes the listener (listenOn does not) and, with force, destroys all open sockets.

## Evidence
- Red first: first attempt (before the socket wrapper) 9 pass, 3 fail (slot-release, slot-release-after-refusal, per-ip-slot-release), 2026-11-06 12:13-12:14, rc=1. Cause: Socket.done unreliable. Fixed with the tracked wrapper.
- connection_cap_test.dart green (+12) 3x: rc=0 at 12:24:44, 12:32:56, 12:45:52 (all `date` stamps start times).
- `dart test -j 1` packages/libreshare_core: rc=0, +2603 passed, 1 skipped (12:50:47-12:57:46). Note: the brief expected >=2607 + new; got 2603 including the 12 new, so the baseline in this clone is 2591: the orchestrator should compare with its own baseline.
- `dart test -j 1` packages/libreshare_cli: rc=0, +75 (12:57:46-12:59:05).
- `dart analyze --fatal-infos lib test/security/connection_cap_test.dart`: rc=0, no issues. `dart format --output=none --set-exit-if-changed` on both lib files: rc=0.

## Defaults for the user's decision: 64 total / 16 per IP
A multi-file Android send uses about 5 parallel sockets (plus keep-alive and an info probe), so 16 per IP leaves 3x headroom; 64 total allows several phones at once. One attacker IP can hold at most 16 of 64 slots, so at least 4 attackers are needed to lock out the rest. The user can change them via the ApiServer constructor arguments maxConnections / maxConnectionsPerIp (not yet wired to a CLI flag or UI setting). Note: NAT/hotspot clients share one IP.

## Risks
- Handshake or head slow-loris is only capped, not timed out: a held slot stays until the peer closes (a handshake/head timeout would be a separate item).
- Wrapping sockets: HttpServer sees `_TrackedSocket` instead of the dart:io socket (kept `is SecureSocket` for TLS); `renegotiate` forwards a deprecated no-op API (lint ignored). Full suites passed.
- Not exercised on Android/Windows hosts; IPv6 per-IP keyed by address string.

## Round 2 (verifier fixes, 2026-11-06 15:32-15:59, clone only)
1. Half-close bypass (X3): the read-side done/error no longer releases a slot; only destroy()/close() of the socket does (once only). X3 now green: 2 of 10 half-closed long-polls reach the handler with per-IP cap 2. The three tester slot-release tests still pass.
2. TLS handshake timeout: new `kDefaultHandshakeTimeout` = 10 s (capped_server_socket.dart), `ApiServer(tlsHandshakeTimeout: ...)`, default 10 s, no CLI flag. On timeout the raw socket is destroyed and the slot released through the same path as a handshake error; a late successful handshake after the timeout is destroyed.
3. stop(force) now also destroys sockets still mid-handshake (tracked in `_pending`). Verifier characterisation probe X4 still prints "closed by stop(force): false" (it only characterises, and passes either way): the raw-socket destroy after secureServer took over apparently does not reach the client in time; not fixed further (LOW).
Results (rc, start time): connection_cap_test.dart +12 3x rc=0 (15:32:21, 15:47:33, 15:51:11); verifier probes (now regular test test/security/connection_cap_verifier_probes_test.dart) +20 rc=0 (15:52:46); core `dart test -j 1` rc=0, +2623 passed, 1 skipped (15:53:06; = 2591 + 12 + 20); cli rc=0, +75 (15:58:18); analyze --fatal-infos lib + test/security rc=0; format check on both lib files rc=0 (15:59:24).
For the user's decision: defaults 64 total, 16 per IP, 10 s TLS handshake timeout. X5 (probe) was written before the fix and only waits 6 s, so it still shows slots held.

## Round 3 (handshake gate, 2026-11-06 21:57-22:27, clone only)
Finding from the verifier: `SecureSocket.secureServer` detaches the fd, so destroy()/close() on the plain Socket after it did nothing; the round 2 timeout released the slot while the TCP connection stayed open.
Change: adopted verifier-tests/fix-proposal-r2-handshake-gate.diff (read line by line; applied cleanly on top of round 2, half-close fix kept). Phase 1: `_readFirstRecord` reads the plain socket until one whole TLS record (first byte 0x16, length <= 16640) is buffered; on timeout (10 s, `kDefaultHandshakeTimeout` / `tlsHandshakeTimeout` kept), close, error or non-TLS first byte the plain socket is destroyed (this really closes it) and the slot freed. Phase 2: `secureServer(bufferedData: record)`, slot stays counted until it settles. stop(force) destroys phase-1 sockets (works now).
No defect found in the proposal. Remaining limit (not a regression): after a COMPLETE first record (ClientHello) a client that then stalls holds its slot, because phase 2 has no timeout and cannot be aborted; it is still counted, so the cap does not under-count.
Results (rc, start): connection_cap_test.dart 3x rc=0 (21:57:45, 22:21:36, 22:23:13); connection_cap_verifier_probes_test.dart rc=0 (22:23:51; X3 2 of 10, X4 closed=true); connection_cap_verifier_round2_test.dart rc=0 (22:24:14; X4 true, X5b true, X8 24 of 24 closed); analyze --fatal-infos lib + test/security rc=0; format check on the two lib files rc=0 (22:27). Full suites not rerun (as instructed).
patch.diff regenerated against the current real files: 2 files, `patch -p1 --dry-run` on a copy of the real tree rc=0.
