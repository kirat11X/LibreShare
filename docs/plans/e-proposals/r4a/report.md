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
