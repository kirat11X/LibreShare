# Security Hygiene Sweep Report (Card A3)

Audit Date: 2026-11-05
Auditor: Subagent A3 (read-only audit)
Scope: `packages/libreshare_core/lib`, `packages/libreshare_cli/lib`, and non-test code under `apps/`

## Step 1: `print(` in `packages/libreshare_core/lib`

Command: `grep -RnE "print\(" packages/libreshare_core/lib` (rc=0)
Command (CLI check): `grep -RnE "print\(" packages/libreshare_cli/lib` (rc=1)

Note: The 29 hits in `libreshare_core` are substring matches for identifier names containing `fingerprint(` or `Fingerprint(`; zero actual calls to Dart's `print()` exist in core.

- `packages/libreshare_core/lib/src/discovery/peer_registry.dart:121`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/discovery/peer_registry.dart:221`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/discovery/peer_registry.dart:239`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/discovery/peer_registry.dart:244`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/discovery/manual_peer.dart:54`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/discovery/manual_peer.dart:61`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/discovery/manual_peer.dart:72`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/discovery/manual_peer.dart:114`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/discovery/manual_peer.dart:177`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/discovery/manual_peer.dart:283`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/discovery/manual_peer.dart:284`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/discovery/manual_peer.dart:466`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:450`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/security/contracts.dart:132`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/security/trust_store.dart:85`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/security/trust_store.dart:114`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/security/trust_store.dart:140`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/security/trust_store.dart:144`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/security/trust_store.dart:182`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/security/trust_store.dart:245`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/security/trust_store.dart:261`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/server/api_server.dart:409`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/client/api_client.dart:179`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/client/api_client.dart:184`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/storage/device_registry.dart:241`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:933`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:961`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1060`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1290`: safe (matched identifier substring `...Fingerprint(...)` rather than the `print()` function).

## Step 2: Logging in `packages/libreshare_core/lib`

Command: `grep -RnE "_log\.(fine|info|warning|severe|shout|finer|finest)" packages/libreshare_core/lib` (rc=0)
Command (CLI check): `grep -RnE "_log\.(fine|info|warning|severe|shout|finer|finest)" packages/libreshare_cli/lib` (rc=1)

Evaluation criteria: checks whether interpolated values include session id >8 chars, fingerprint >16 hex, PIN, nonce, token, key, file name, or `$e`/`$err` of unknown exceptions.

- `packages/libreshare_core/lib/src/discovery/multicast_transport.dart:107`: suspicious: interpolates `$e` of unknown exception (could leak OS socket details).
- `packages/libreshare_core/lib/src/discovery/multicast_transport.dart:114`: suspicious: interpolates `$e` of unknown exception in socket stream onError handler.
- `packages/libreshare_core/lib/src/discovery/multicast_transport.dart:145`: suspicious: interpolates `$e` of unknown exception on bind failure.
- `packages/libreshare_core/lib/src/discovery/multicast_transport.dart:162`: suspicious: interpolates `$e` of unknown exception when listing network interfaces.
- `packages/libreshare_core/lib/src/discovery/multicast_transport.dart:180`: suspicious: interpolates `$e` of unknown exception when listing network interfaces.
- `packages/libreshare_core/lib/src/discovery/multicast_transport.dart:195`: suspicious: interpolates `$e` of unknown exception when joining multicast group.
- `packages/libreshare_core/lib/src/discovery/multicast_transport.dart:204`: suspicious: interpolates `$e` of unknown exception when multicast join fails on all interfaces.
- `packages/libreshare_core/lib/src/discovery/multicast_transport.dart:207`: safe: logs group IP, port, and integer interface count.
- `packages/libreshare_core/lib/src/discovery/multicast_transport.dart:218`: suspicious: interpolates `$e` of unknown exception on multicast leave.
- `packages/libreshare_core/lib/src/discovery/multicast_transport.dart:242`: suspicious: interpolates `$e` of unknown exception on multicast send.
- `packages/libreshare_core/lib/src/discovery/multicast_transport.dart:249`: suspicious: interpolates `$e` of unknown exception on multicast send.
- `packages/libreshare_core/lib/src/discovery/multicast_transport.dart:259`: suspicious: interpolates `$e` of unknown exception on unicast send.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:197`: suspicious: interpolates `$e` of unknown exception from packet stream.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:271`: suspicious: interpolates `$e` of unknown exception from user-provided refresh hook.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:300`: safe: logs only `${e.runtimeType}`.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:314`: suspicious: interpolates `$e` of unknown exception on multicast announcement.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:335`: safe: logs own port number only.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:348`: suspicious: interpolates `$e` of unknown exception (announcement signing/crypto error).
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:382`: suspicious: interpolates `$e` of unknown exception handling incoming packet.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:530`: suspicious: interpolates `$e` of unknown exception on unicast reply to peer IP.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:545`: safe: logs peer IP address only.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:552`: suspicious: interpolates `$e` of unknown exception registering at peer IP.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:557`: suspicious: interpolates `$e` of unknown exception registering at peer IP.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:569`: suspicious: interpolates `$e` of unknown exception listing interfaces.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:595`: safe: constant informational string.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:599`: suspicious: interpolates `$e` of unknown exception on interface rejoin.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:604`: suspicious: interpolates `$e` of unknown exception during interface polling.
- `packages/libreshare_core/lib/src/security/trust_store.dart:213`: safe: logs fingerprints truncated to 16 hex characters via `shortFp`.
- `packages/libreshare_core/lib/src/security/trust_store.dart:235`: safe: logs fingerprint truncated via `shortFp` and trust level enum name.
- `packages/libreshare_core/lib/src/security/trust_store.dart:252`: safe: logs fingerprint truncated via `shortFp`.
- `packages/libreshare_core/lib/src/security/trust_store.dart:264`: safe: logs fingerprint truncated via `shortFp`.
- `packages/libreshare_core/lib/src/security/trust_store.dart:277`: safe: constant informational string.
- `packages/libreshare_core/lib/src/security/trust_store.dart:296`: safe: logs trust enum name only.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:186`: safe: constant warning message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:376`: safe: constant warning message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:381`: safe: constant warning message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:384`: safe: constant warning message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:387`: safe: constant warning message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:390`: safe: constant warning message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:393`: safe: constant warning message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:396`: safe: logs fingerprint truncated via `shortFp`.
- `packages/libreshare_core/lib/src/transfer/file_sender.dart:181`: safe: logs session ID truncated via `_shortId` and bytes sent count.
- `packages/libreshare_core/lib/src/transfer/file_sender.dart:201`: safe: logs truncated session ID, wire failure reason, and `e.runtimeType`.
- `packages/libreshare_core/lib/src/transfer/file_sender.dart:535`: safe: logs truncated session/file IDs and remaining chunk count.
- `packages/libreshare_core/lib/src/transfer/file_sender.dart:658`: safe: logs `e.runtimeType` and retry count.
- `packages/libreshare_core/lib/src/transfer/file_sender.dart:773`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/transfer/file_sender.dart:783`: safe: constant string, error object passed to logger parameter without string interpolation.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:299`: safe: logs old and new fingerprints truncated to 16 hex via `shortFp`.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:408`: safe: logs truncated session ID, remote IP, and file/byte counts.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:484`: safe: logs session ID truncated to 8 characters via `_short`.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:487`: safe: logs session ID truncated to 8 characters via `_short`.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:740`: suspicious: interpolates `${e.message}` from `FileSystemException` which could expose path or system details.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:882`: safe: logs session ID truncated via `_short`.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1066`: safe: logs `err.runtimeType`.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1264`: suspicious: interpolates `${e.message}` from `FileSystemException` on session preparation.
- `packages/libreshare_core/lib/src/server/api_server.dart:201`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/server/api_server.dart:204`: safe: logs bind address and port.
- `packages/libreshare_core/lib/src/server/api_server.dart:215`: safe: logs port numbers.
- `packages/libreshare_core/lib/src/server/api_server.dart:424`: safe: logs `body.upstreamError.runtimeType`.
- `packages/libreshare_core/lib/src/server/api_server.dart:430`: safe: logs `e.runtimeType` and HTTP method.
- `packages/libreshare_core/lib/src/server/api_server.dart:711`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/storage/receive_settings_store.dart:70`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/storage/file_secret_store.dart:184`: safe: constant warning message.
- `packages/libreshare_core/lib/src/storage/file_secret_store.dart:189`: safe: constant warning message.
- `packages/libreshare_core/lib/src/storage/file_secret_store.dart:194`: safe: constant warning message.
- `packages/libreshare_core/lib/src/storage/file_secret_store.dart:200`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/storage/file_secret_store.dart:224`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/storage/file_secret_store.dart:240`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/storage/file_secret_store.dart:261`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/storage/device_registry.dart:291`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/storage/device_registry.dart:300`: safe: logs count of skipped unusable entries.
- `packages/libreshare_core/lib/src/storage/device_registry.dart:334`: safe: constant warning message.
- `packages/libreshare_core/lib/src/storage/device_registry.dart:336`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/storage/credential_store.dart:225`: safe: constant informational string.
- `packages/libreshare_core/lib/src/storage/credential_store.dart:227`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/storage/credential_store.dart:267`: safe: logs enum name and `cause.runtimeType`.
- `packages/libreshare_core/lib/src/storage/credential_store.dart:289`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/storage/credential_store.dart:358`: safe: logs fingerprint truncated via `shortFp`.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:318`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1021`: safe: constant warning message.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1023`: safe: constant warning message.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1025`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1103`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1210`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1252`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1273`: suspicious: interpolates `$e` of unknown exception from mDNS browse stream.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1276`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1309`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1324`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/receive/receive_controller.dart:71`: suspicious: interpolates `$e` of unknown exception from environment stream.
- `packages/libreshare_core/lib/src/receive/receive_controller.dart:249`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/receive/receive_controller.dart:466`: safe: logs `e.runtimeType`.
- `packages/libreshare_core/lib/src/receive/receive_controller.dart:613`: safe: logs `e.runtimeType`.

## Step 3: Exception messages and `toString()` in `packages/libreshare_core/lib/src/{server,transfer,security,client}`

Command: `grep -RnE "toString\(\)|message:|LsException\(" packages/libreshare_core/lib/src/{server,transfer,security,client}` (rc=0)

Evaluation criteria: checks for exception texts containing user- or peer-controlled data (reflected over wire or into logs).

- `packages/libreshare_core/lib/src/server/api_server.dart:342`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:426`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:435`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:439`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:482`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:492`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:495`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:504`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:508`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:524`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:526`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:538`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:541`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:546`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:554`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:569`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:576`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:591`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:603`: safe: `$what` is hardcoded constant argument name passed by server.
- `packages/libreshare_core/lib/src/server/api_server.dart:624`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:651`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:667`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:733`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:744`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:770`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:780`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:785`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:813`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:819`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:826`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:831`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:834`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:886`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:975`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:1010`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:1017`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/server/api_server.dart:1023`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/chunker.dart:15`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/transfer/hashing.dart:18`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/transfer/hashing.dart:87`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:101`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:158`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:223`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:254`: safe: `why` parameter is limited to hardcoded constant strings ('dot-dot segment', 'unresolvable link', 'outside').
- `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:369`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:383`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart:402`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_sender.dart:68`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/transfer/file_sender.dart:703`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/transfer/file_sender.dart:747`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/transfer/file_sender.dart:753`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/transfer/file_sender.dart:857`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:246`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:249`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:271`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:278`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:282`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:291`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:296`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:310`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:340`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:348`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:435`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:439`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:449`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:497`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:547`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:556`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:563`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:567`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:571`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:581`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:605`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:674`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:677`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:685`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:706`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:719`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:725`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:726`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:735`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:741`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:783`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:793`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:798`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:805`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:848`: suspicious: reflects peer-controlled `item.fileId` into `LsException` message sent over the wire.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:877`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:883`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:936`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:960`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:964`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:973`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:976`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:988`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:990`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:993`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:995`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1000`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1090`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1096`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1099`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1105`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1112`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1115`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1118`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1121`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1124`: suspicious: reflects peer-controlled `f.fileId` into `LsException` message sent over the wire.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1131`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1136`: safe: echoes peer-provided integer totalSize and sum in validation error.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1157`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1170`: suspicious: reflects internal disk space threshold (`$needed bytes`) in `LsException` sent to peer.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1209`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1266`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1285`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1409`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/crypto_primitives.dart:19`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/crypto_primitives.dart:175`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/der.dart:20`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/der.dart:154`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/der.dart:167`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/trust_store.dart:49`: safe: exception `toString()` includes `deviceId`; handled internally and not sent over wire.
- `packages/libreshare_core/lib/src/security/trust_store.dart:57`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/cert_factory.dart:49`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/cert_factory.dart:58`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/sas.dart:110`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/identity_proof.dart:92`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/identity_proof.dart:99`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/key_identity.dart:46`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/key_identity.dart:133`: safe: `KeyIdentity.toString()` logs `deviceId` and `shortFp` (never private key).
- `packages/libreshare_core/lib/src/security/pin_guard.dart:69`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/pin_guard.dart:114`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pin_guard.dart:124`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pin_guard.dart:167`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pin_guard.dart:170`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:233`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:238`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:241`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:254`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:263`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:268`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:278`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:281`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:460`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:477`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:487`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:491`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/security/pairing_service.dart:494`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/client/api_client.dart:448`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/client/api_client.dart:459`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/client/api_client.dart:476`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/client/api_client.dart:484`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/client/api_client.dart:486`: safe: `LsException` uses fixed constant error message.
- `packages/libreshare_core/lib/src/client/peer_security_exceptions.dart:18`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.
- `packages/libreshare_core/lib/src/client/peer_security_exceptions.dart:36`: safe: fingerprints in `toString()` are truncated to 16 hex characters via `shortFp`.
- `packages/libreshare_core/lib/src/client/peer_security_exceptions.dart:47`: safe: `toString()` formats internal types/hashes without leaking sensitive user secrets.

## Step 4: `TODO|FIXME|XXX|HACK` in `packages` and `apps`

Command: `grep -RnE "TODO|FIXME|XXX|HACK" packages apps --include=*.dart` (ignoring `test/` and `.dart_tool/`) (rc=0)

Note: `packages/` contains 0 hits (clean). `apps/libreshare_app/lib` contains 1 hit. Remaining 13 hits are in ephemeral platform plugin symlinks.

- `apps/libreshare_app/lib/platform/environment/polling_network_environment.dart:13`: safe: documentation comment describing deferred battery/screen event handling.
- `apps/libreshare_app/windows/flutter/ephemeral/.plugin_symlinks/jni/lib/src/errors.dart:12`: safe: third-party/generated code in build ephemeral plugin symlink.
- `apps/libreshare_app/windows/flutter/ephemeral/.plugin_symlinks/jni/lib/src/errors.dart:50`: safe: third-party/generated code in build ephemeral plugin symlink.
- `apps/libreshare_app/windows/flutter/ephemeral/.plugin_symlinks/jni/lib/src/jni.dart:192`: safe: third-party/generated code in build ephemeral plugin symlink.
- `apps/libreshare_app/windows/flutter/ephemeral/.plugin_symlinks/jni/lib/src/util/jlist.dart:65`: safe: third-party/generated code in build ephemeral plugin symlink.
- `apps/libreshare_app/windows/flutter/ephemeral/.plugin_symlinks/jni/lib/src/util/jmap.dart:82`: safe: third-party/generated code in build ephemeral plugin symlink.
- `apps/libreshare_app/windows/flutter/ephemeral/.plugin_symlinks/jni/lib/src/util/jset.dart:53`: safe: third-party/generated code in build ephemeral plugin symlink.
- `apps/libreshare_app/windows/flutter/ephemeral/.plugin_symlinks/path_provider_windows/lib/src/path_provider_windows_real.dart:273`: safe: third-party/generated code in build ephemeral plugin symlink.
- `apps/libreshare_app/linux/flutter/ephemeral/.plugin_symlinks/jni/lib/src/errors.dart:12`: safe: third-party/generated code in build ephemeral plugin symlink.
- `apps/libreshare_app/linux/flutter/ephemeral/.plugin_symlinks/jni/lib/src/errors.dart:50`: safe: third-party/generated code in build ephemeral plugin symlink.
- `apps/libreshare_app/linux/flutter/ephemeral/.plugin_symlinks/jni/lib/src/jni.dart:192`: safe: third-party/generated code in build ephemeral plugin symlink.
- `apps/libreshare_app/linux/flutter/ephemeral/.plugin_symlinks/jni/lib/src/util/jlist.dart:65`: safe: third-party/generated code in build ephemeral plugin symlink.
- `apps/libreshare_app/linux/flutter/ephemeral/.plugin_symlinks/jni/lib/src/util/jmap.dart:82`: safe: third-party/generated code in build ephemeral plugin symlink.
- `apps/libreshare_app/linux/flutter/ephemeral/.plugin_symlinks/jni/lib/src/util/jset.dart:53`: safe: third-party/generated code in build ephemeral plugin symlink.

## Step 5: `http://` in `packages/libreshare_core/lib`

Command: `grep -RnE "http://" packages/libreshare_core/lib` (rc=1)
Command (CLI check): `grep -RnE "http://" packages/libreshare_cli/lib` (rc=1)

- (no hits): safe: core never uses hardcoded `http://` URLs; all URIs are constructed via `Uri(scheme: ...)` where scheme defaults to `'https'` in secure mode and only uses `'http'` for the plaintext profile.

## Step 6: `badCertificateCallback|allowInsecure|insecure` in Core and CLI

Command: `grep -RnE "badCertificateCallback|allowInsecure|insecure" packages/libreshare_core/lib packages/libreshare_cli/lib` (rc=0)

- `packages/libreshare_core/lib/src/discovery/subnet_scanner.dart:97`: safe: used only in secure probe to read `/api/v1/info`; immediately validates presented certificate hash against advertised fingerprint before accepting peer.
- `packages/libreshare_core/lib/src/security/contracts.dart:259`: safe: `allowInsecurePeers` default initializer is `false`.
- `packages/libreshare_core/lib/src/security/contracts.dart:266`: safe: `allowInsecurePeers` constructor default is `false`.
- `packages/libreshare_core/lib/src/security/contracts.dart:274`: safe: doc comment specifying `allowInsecurePeers` is CLI `--allow-insecure` only.
- `packages/libreshare_core/lib/src/security/contracts.dart:275`: safe: `allowInsecurePeers` field declaration.
- `packages/libreshare_core/lib/src/security/tls_context.dart:6`: safe: doc comment explaining client certificate verification design.
- `packages/libreshare_core/lib/src/security/tls_context.dart:29`: safe: doc comment describing `buildClientContext` usage with `badCertificateCallback`.
- `packages/libreshare_core/lib/src/transfer/file_sender.dart:318`: safe: enforces security by throwing `InsecurePeerException` unless `allowInsecurePeers` is explicitly enabled.
- `packages/libreshare_core/lib/src/client/api_client.dart:46`: safe: `badCertificateCallback` constructor parameter for custom/testing setups.
- `packages/libreshare_core/lib/src/client/api_client.dart:60`: safe: sets `_http.badCertificateCallback` to `_checkCertificate` which pins server certificate or records it for SAS verification.
- `packages/libreshare_core/lib/src/client/api_client.dart:62`: safe: allows custom `badCertificateCallback` only in insecure/testing mode.
- `packages/libreshare_core/lib/src/client/api_client.dart:63`: safe: assignments of custom `badCertificateCallback`.
- `packages/libreshare_core/lib/src/engine/security_wiring.dart:55`: safe: `allowInsecurePeers` parameter defaults to `false`.
- `packages/libreshare_core/lib/src/engine/security_wiring.dart:92`: safe: passes `allowInsecurePeers` to `SecurityConfig`.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:954`: safe: falls back to plaintext only if `allowInsecurePeers` is explicitly configured.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:968`: safe: falls back to plaintext only if `allowInsecurePeers` is explicitly configured.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:977`: safe: falls back to plaintext only if `allowInsecurePeers` is explicitly configured.
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1419`: safe: doc comment describing `--allow-insecure` flag behaviour.
- `packages/libreshare_cli/lib/ls_cli.dart:5`: safe: CLI doc comment describing `--insecure-plaintext` option.
- `packages/libreshare_cli/lib/ls_cli.dart:8`: safe: CLI doc comment listing exit code 81 for insecure peer.
- `packages/libreshare_cli/lib/ls_cli.dart:40`: safe: CLI help text showing `--insecure-tofu` option.
- `packages/libreshare_cli/lib/ls_cli.dart:42`: safe: CLI help text showing `--insecure-tofu` and `--allow-insecure` options.
- `packages/libreshare_cli/lib/ls_cli.dart:51`: safe: CLI usage text documenting `--secure` vs `--insecure-plaintext`.
- `packages/libreshare_cli/lib/ls_cli.dart:226`: safe: CLI flag definition for `--insecure-plaintext` (opt-in for loopback/tests).
- `packages/libreshare_cli/lib/ls_cli.dart:234`: safe: CLI doc comment on resolving `--secure` / `--insecure-plaintext`.
- `packages/libreshare_cli/lib/ls_cli.dart:242`: safe: CLI parameter `allowInsecure` defaults to `false`.
- `packages/libreshare_cli/lib/ls_cli.dart:245`: safe: CLI checks that `--secure` and `--insecure-plaintext` exclude each other.
- `packages/libreshare_cli/lib/ls_cli.dart:246`: safe: CLI error message on conflicting secure/insecure flags.
- `packages/libreshare_cli/lib/ls_cli.dart:254`: safe: CLI handling of `--insecure-plaintext` flag.
- `packages/libreshare_cli/lib/ls_cli.dart:263`: safe: passes CLI `allowInsecure` flag to security wiring.
- `packages/libreshare_cli/lib/ls_cli.dart:465`: safe: CLI flag definition for `--insecure-tofu`.
- `packages/libreshare_cli/lib/ls_cli.dart:503`: safe: CLI flag definition for `--insecure-tofu`.
- `packages/libreshare_cli/lib/ls_cli.dart:508`: safe: CLI flag definition for `--allow-insecure`.
- `packages/libreshare_cli/lib/ls_cli.dart:769`: safe: CLI validates that contacts-only mode cannot be combined with insecure plaintext.
- `packages/libreshare_cli/lib/ls_cli.dart:802`: safe: CLI reads `insecure-tofu` flag.
- `packages/libreshare_cli/lib/ls_cli.dart:946`: safe: CLI doc comment on `--insecure-tofu`.
- `packages/libreshare_cli/lib/ls_cli.dart:1010`: safe: CLI parses `allow-insecure` flag.
- `packages/libreshare_cli/lib/ls_cli.dart:1013`: safe: CLI reads `insecure-tofu` flag.
- `packages/libreshare_cli/lib/ls_cli.dart:1449`: safe: CLI validates that `pair` command refuses insecure plaintext mode.

## Summary of Suspicious Items (Requiring Orchestrator Review)

### 1. Raw `$e` Exception Interpolation in Log Messages (24 sites)
In `packages/libreshare_core/lib`, several log statements interpolate `$e` directly rather than `${e.runtimeType}`. While mostly socket/network errors, unknown exceptions may expose filesystem paths or network details:
- `packages/libreshare_core/lib/src/discovery/multicast_transport.dart`: lines 107, 114, 145, 162, 180, 195, 204, 218, 242, 249, 259
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart`: lines 197, 271 (user hook!), 314, 348 (crypto/announcement), 382 (packet processing), 530, 552, 557, 569, 599, 604
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart`: line 1273 (mDNS browse stream error)
- `packages/libreshare_core/lib/src/receive/receive_controller.dart`: line 71 (env stream error)

### 2. `${e.message}` on `FileSystemException` in Logs (2 sites)
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:740`: `_log.warning('chunk write failed: ${e.message}');`
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1264`: `_log.warning('cannot start session ${_short(s.id)}: ${e.message}');`
`FileSystemException.message` or OS error details can contain filesystem paths.

### 3. Peer-Controlled Data Reflected in Wire Error Responses (3 sites)
`LsException.toEnvelope()` returns `message` directly to the peer over HTTP JSON error response:
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:848`: `SHA-256 of ${item.fileId} does not match; partial file removed` (reflects peer's unvalidated `fileId`)
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1124`: `chunkCount of ${f.fileId} does not match its size` (reflects peer's unvalidated `fileId`)
- `packages/libreshare_core/lib/src/transfer/file_receiver.dart:1170`: `not enough free space (need $needed bytes)` (reveals internal storage requirement/headroom to peer)

