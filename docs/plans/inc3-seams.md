# Increment 3 — integration seams between work packages (orchestrator-owned, 2026-11-04)

Binding for P3 (server), P4 (receiver/consent/pairing), P5 (client/sender), P6b (discovery) and later P6a (engine/CLI).
Source of truth for behaviour: `docs/protocol/LSP-1.md` (sections 0.3, 4.3.1–4.3.6, 4.7, 5, 6), `docs/protocol/test-vectors-inc3.md`, `docs/plans/inc3.md`.
Source of truth for types: `packages/libreshare_core/lib/src/security/contracts.dart` and the P1/P2 modules listed below. **Do not edit orchestrator-owned files** (CLAUDE.md list, `contracts.dart`, the barrel, pubspecs, `docs/plans/*`); report what you need.

## Rules that apply to every package

1. **Plaintext profile = Inc 1/2 behaviour, byte for byte.** Every existing test (1614 core, 41 CLI, 249 app) must keep passing with **no edits to any existing test or fixture**. All new behaviour is gated on `SecurityConfig.isSecure`. New behaviour gets new test files.
2. Tests first, shown failing for the right reason. Real exit codes. No `print`, no Flutter, no network outside loopback. Never log keys, PINs, nonces, tokens or full fingerprints (`shortFp` = 16 hex max); exceptions carry fixed text.
3. File ownership is exclusive; new test helpers go in **new** files named after your package (e.g. `test/helpers/p3_*.dart`). Do not leave scratch files.
4. A secure test needs identities: `generateIdentityFor(deviceId)` (~20 ms) + `KeyIdentity.fromGenerated`, `InMemoryTrustStore`, `InMemorySecretStore`. Fixed key vectors live in `docs/protocol/test-vectors-inc3.md`.
5. Use `package:libreshare_core/src/security/crypto_primitives.dart` directly for `sha256Hex` (the barrel hides that one name because a legacy test helper defines its own).

## Already landed constructor/interface seams (do not rename; fill in the behaviour)

| Where | Seam | Owner of the behaviour |
|---|---|---|
| `server/incoming_transfer_handler.dart` | `SecureTransferHandler extends IncomingTransferHandler`: `createAuthenticatedSession(request,{remoteAddress,peer})`, `revealSas(sid,{nonce,peer})`, `pair(request,{remoteAddress,peer})`, `incomingInfo(sid)` | P4 implements in `FileReceiver`; P3 calls |
| `client/peer_client.dart` | `SecurePeerClient extends PeerClient`: `serverFingerprint`, `revealSas`, `pair` | P5 implements in `ApiClient`; P5's `FileSender` uses; P6b's probes use `ApiClient` |
| `ApiServer(security:, contactsOnly:)` | `security.isSecure` ⇒ TLS 1.3 listener via `buildServerContext(identity)`, handler must be a `SecureTransferHandler` (else `ArgumentError`); `contactsOnly` evaluated per request | P3 |
| `FileReceiver(security:, pinVerifier:)` | now `implements SecureTransferHandler`; the four new methods are stubs | P4 |
| `ApiClient(security:, expectedFingerprint:)` | secure ⇒ HTTPS, `buildClientContext`, pin via `certificateMatchesPin`; `expectedFingerprint == null` ⇒ first contact (accept any cert for the handshake, expose `serverFingerprint`, caller must run SAS) | P5 |
| `PinVerifier` (contracts) | `enforced`, `check(remoteAddress,pin,exempt)`, `consume()` | P3 writes `security/pin_guard.dart` (`PinGuard implements PinVerifier`, plus `currentPin`, `rotate()`, ctor `onBruteForce` callback, injectable `Clock`); P4 calls it at check-order step 9 |

## Surface decided by the P5 tests (orchestrator accepted 2026-11-05; P6a depends on it)

- `FileSender({..., SecurityConfig security = const SecurityConfig.plaintext(), String? pinnedReceiverFingerprint})`.
- `SendResult.receiverFingerprint` (`String?`): set only when the session was accepted in the secure profile, so a rejected receiver is never pinned. P6a pins it (as `known`) when the session was reached through a SAS flow.
- In the secure profile `FileSender` calls `client.info()` first to learn the receiver fingerprint; the plaintext profile must not (byte-identical request sequence).
- `send()` throws `InsecurePeerException` / `PeerFingerprintMismatchException` / `SasAbortedException` (file `client/peer_security_exceptions.dart`, imported by path; the orchestrator adds the barrel export once the file exists) and returns a `SendResult` for everything else. A pinned `GET /info` always carries `X-LS-Auth`, an unpinned one never does. An empty `/info.fingerprint` => `InsecurePeerException`; a different non-empty one => `PeerFingerprintMismatchException`. An unpinned client locks onto the first certificate it saw and refuses a swapped one.

## Data flow and who checks what (secure profile, POST /sessions)

1. **P3 (server)** terminates TLS, applies the Contacts-only gate (`contactsOnly()` true and the caller has no valid proof / is not a contact ⇒ plain `404 NOT_FOUND` identical to an unknown route), rate limit, body-size caps (4 MiB for `POST /sessions`, 256 KiB elsewhere; `Content-Length` required above 256 KiB; ≤ 2 oversize bodies at once), then `verifyAuthHeader(...)` with `ownFingerprint = security.identity.identity.fingerprint`, a server-wide `NonceCache`, and `pathAndQueryOf(uri)`. On success it builds `AuthenticatedPeer` and calls `handler.createAuthenticatedSession(request, remoteAddress, peer)`; on failure `401 AUTH_INVALID`. It adds `Date` to every secure response and requires `X-LS-Chunk-SHA256` on chunk PUTs in the secure profile. `/pair` is exempt from the Contacts-only gate.
2. **P4 (receiver)** continues the check order of LSP-1 4.3.4 from "shape/consistency": sender-vs-proof match (`request.sender.deviceId` and `.fingerprint` must equal the proof's, else `AUTH_INVALID`), `TrustStore.classify` (blocked ⇒ `403 BLOCKED`; key changed ⇒ `403 KEY_CHANGED` + `PeerKeyChanged` event), PIN (`pinVerifier.check(..., exempt: trusted && policy.exemptContacts)`), storage (507), pending caps (3 per IP / 8 total ⇒ 429), BUSY, then SAS/consent.
3. **P5 (client)** signs every request that needs a proof with `buildAuthHeader(identity, method, pathAndQuery, body, serverFingerprint: <fingerprint seen in this connection's handshake>)`; sends `sasCommit` iff it has no pin for the receiver; reveals `Ns` right after the 202 that carries `sas.nonce`; emits `SasReady(outgoing: true)`.
4. **SAS** (D4): receiver stores the commit, picks `Nr`, returns it in `SessionStatus.sas`; after `revealSas` verifies the commit against **its own** fingerprint it computes the code and emits `SasReady(outgoing: false)`; **Accept is refused until the code exists**; a receiver that was given a commit never auto-accepts; reveal deadline `kSasRevealTimeout` ⇒ `FAILED(TIMEOUT)`; commit mismatch ⇒ `401 AUTH_INVALID` and session `FAILED(PROTOCOL_ERROR)`.
5. **Pinning after first contact:** the receiver pins the sender as `known` when the user accepts a SAS-confirmed session (`ContactChanged` event); the sender pins the receiver as `known` when its session reaches `IN_PROGRESS` after a SAS flow (`SendResult`/callback exposes the receiver fingerprint; P6a performs the pin). A session from a pinned peer with a **different** key is refused with `KEY_CHANGED` and never auto-replaced.
6. **Legacy peers:** a peer whose `DeviceInfo.fingerprint` is empty is "legacy". A secure sender refuses it locally (0 bytes sent) unless `SecurityConfig.allowInsecurePeers`; a secure client never falls back from TLS to HTTP; a TLS-only listener answers a plaintext client by closing the connection (no body).
7. **Discovery (P6b):** announces carry the fingerprint; probes and `/register` use HTTPS in the secure profile and **reject a peer whose `/info.fingerprint` differs from the SHA-256 of the certificate it presented**; an announce/probe with an empty or different fingerprint never overrides a pinned device; signed `bye` datagram (domain `SigDomain.bye`, message `deviceId + fingerprint + ts` as in LSP-1 rule 9, replay-protected, only accepted when the registry already holds the peer's certificate); `PeerRegistry.remove`; Contacts-only reply filter (reply with the real port only to announcers whose fingerprint is a trusted contact; this is privacy, the access control is the server gate).

## Exceptions crossing package boundaries (defined by the package named, in its own file)

- P5: `InsecurePeerException` (peer spoke plaintext / has no fingerprint / TLS expected), `PeerFingerprintMismatchException(expectedShort, presentedShort)` (pin mismatch at handshake), `SasAbortedException`. All carry fixed text and short fingerprints only.
- P2 (exists): `KeyChangedException`, `FingerprintInUseException`, `RegistryFullException`, `IdentityLostException`.
- P3: none public (maps to `LsException`).

## Definition of done for every package

From the repo root, `source tools/env.sh`, real exit codes:

```
dart format --output=none --set-exit-if-changed .          # 0
dart analyze --fatal-infos                                 # 0
(cd packages/libreshare_core && dart test <your new files>) # 0, three runs
(cd packages/libreshare_core && dart test)                 # 0 (baseline 1614 passed, 1 skipped; other agents' new tests are included, so report the delta of yours)
(cd packages/libreshare_cli && dart test)                  # 0 (41)
grep -RnE "package:flutter|dart:ui" packages/libreshare_core/lib   # no match
```

plus: your tests demonstrably failed first; one mutation check for your area (apply, show red, restore, verify by `diff`); no file outside your ownership list changed.
