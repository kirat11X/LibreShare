# LSP/1 - LibreShare Protocol, versions 1.0 and 1.1

| | |
|---|---|
| Status | Draft, normative for LibreShare Increment 1 and later. Version 1.0 is the plaintext profile (Increments 1 and 2); version 1.1 is the secure profile of Increment 3 and is marked **[I3]** throughout |
| Source of truth | `docs/LIBRESHARE_BUILD_SPEC.md` section 4 (this file refines it; on conflict, fix both in the same change) |
| Wire models | `packages/libreshare_core/lib/src/{protocol.dart,model/*.dart}` |
| Schemas | `docs/protocol/schemas/*.schema.json` and, for the messages new in 1.1, `docs/protocol/schemas/lsp11/*.schema.json` (JSON Schema draft 2020-12; the `$id` of every schema is independent of the directory) |
| Test vectors | `docs/protocol/test-vectors-inc3.md` (SAS commit and code, `X-LS-Auth`, HKDF; known-answer values produced by the crypto package) |
| Rationale | `docs/adr/0004-authentication-model.md`, `docs/adr/0005-sas-commit-reveal.md` |
| Rule | A protocol change MUST update this file, the schemas and the conformance tests in the same pull request (spec section 4.6, CLAUDE.md). |

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as in RFC 2119.

## 0. Scope and increment markers

LSP/1 is the wire protocol between two LibreShare instances: UDP/mDNS discovery, a REST API over TLS 1.3 with a pinned server certificate and a signed client proof [I3], SHA-256-verified 4 MiB resumable chunks, and an end-to-end-encrypted internet tunnel fallback. It is built incrementally (spec section 12). Every rule below carries a marker saying when it becomes real:

| Marker | Meaning |
|---|---|
| **[I1]** | Implemented and tested in Increment 1 (this increment): REST over plain HTTP, no TLS, no discovery, peer address given on the command line. |
| **[I2]** | Increment 2: discovery (multicast, mDNS, subnet scan, QR/manual), `/register` callers, port fallback, discovery-side version filtering. |
| **[I3]** | Increment 3 (LSP/1.1, the secure profile): TLS 1.3 with a pinned server certificate, signed client proof (`X-LS-Auth`), fingerprints, SAS commit/reveal and TOFU, PIN, rate limits, consent prompt, Contacts-only visibility, QR pairing, `bye` datagram, sanitizer hardening, corruption handling. |
| **[I4]** | Increment 4: connection ladder, durable resume bitmap, `/state`-driven resync across channels. |
| **[I5]** | Increment 5: tunnel origin API, tunnel crypto, `tunnelOffer`. |

Rules without a marker apply from the increment that first touches the feature. Unmarked data formats (JSON members, status codes) are fixed in Increment 1 so that later increments only add behaviour.

### 0.1 Increment 1 profile

In Increment 1 the protocol is exercised as follows:

- Transport is **plain HTTP** (`http://host:port/api/v1`). There is no TLS, no certificate, no fingerprint pinning. `DeviceInfo.fingerprint` is the empty string. This profile MUST only be used on loopback, a Docker test network, or another network the operator trusts. It exists to prove chunking, hashing, resume plumbing and the HTTP contract (the transport sits behind an interface and is replaced by `bindSecure` in Increment 3).
- There is **no discovery**. The sender is given `host:port` (`ls send --to host:port`). `GET /info` MAY be used to identify the peer.
- Consent is reduced to **auto-accept** on the receiver (`ls receive --auto-accept`): `POST /sessions` returns `200` with `IN_PROGRESS` and tokens. The `PENDING` path, long-poll and `202` are specified here and covered by handler/server unit tests, but the interactive prompt and the 120 s timeout acceptance belong to [I3].
- `pin` is accepted and ignored; `BLOCKED`, `PIN_REQUIRED`, `PIN_INVALID` are not emitted. The per-IP request-rate limit on `POST /sessions` (`RATE_LIMITED`) and the `426` major-version check ARE enforced by `ApiServer` in Increment 1. `POST /register` is served (the route exists) but nothing calls it until discovery lands in [I2].
- `tunnelOffer` is absent or `null`.
- Everything else in sections 4.3 and 4.4 (endpoints, headers, chunk hashing, ranges, completion, error envelope) is fully in force.
- From Increment 3 this profile remains defined as the **plaintext profile** (0.3): it is the LSP/1.0 wire, used on loopback and in test networks.

### 0.2 Conventions

Section numbers 4.x, 5 and 6 below deliberately match the build spec (`docs/LIBRESHARE_BUILD_SPEC.md`).

- Bodies are UTF-8 JSON (`Content-Type: application/json`), except chunk bodies (`application/octet-stream`).
- Unknown JSON members MUST be ignored by every implementation (spec 4.6). Missing optional members take the defaults given in the schemas.
- Integers are 64-bit-safe. File sizes and offsets MUST NOT be truncated to 32 bits (files over 4 GiB are supported).
- Timestamps are ISO-8601 in UTC (`2026-10-30T10:00:00Z`).
- **Hex case matters.** Emitters MUST write file and chunk SHA-256 values as **lowercase** hex (64 chars); receivers accept either case on input (`X-LS-Chunk-SHA256`, `complete` body) and normalise to lowercase. Certificate fingerprints are **uppercase** hex SHA-256 of the DER certificate (64 chars). Truncated fingerprints (`fp` in mDNS TXT and tunnel links) are the first 16 characters of the uppercase fingerprint.
- Tokens and keys are base64url without padding. A receiver SHOULD tolerate trailing `=`.
- HTTP header names are case-insensitive. The canonical spelling is `X-LS-Chunk-SHA256`; the Dart constant is the lowercase `x-ls-chunk-sha256` (`kChunkHashHeader`) because `dart:io` normalises names.
- Unknown query parameters MUST be ignored.

### 0.3 Transport profiles and LSP/1.1  **[I3]**

LSP/1.1 is the secure profile of LSP/1. Its JSON and routes are additive to LSP/1.0: no member, route or status changes meaning, every new member is optional, and a peer that does not know a member ignores it (0.2). Its transport is not compatible with plain HTTP, by design. Two profiles exist:

| | Plaintext profile | Secure profile |
|---|---|---|
| `v` reported | `1.0` (`kProtocolVersion`) | `1.1` (`kProtocolVersionSecure`) |
| Transport | plain HTTP, `http://host:port/api/v1` | HTTPS, TLS 1.3 only, `https://host:port/api/v1` |
| `DeviceInfo.fingerprint` | empty string | 64 uppercase hex, equal to the hash of the TLS certificate |
| Server identity | none | self-signed identity certificate, pinned by the client (first contact: SAS, 5.1) |
| Client identity | none | `X-LS-Auth` proof on the routes of 4.3.6 |
| Routes | exactly the LSP/1.0 routes; `/sessions/{sid}/sas` and `/pair` answer 404 | all routes of 4.3.2 |
| `POST /sessions` body limit | 256 KiB | 4 MiB |
| `X-LS-Chunk-SHA256` | optional (verified when present) | mandatory (400 BAD_REQUEST when missing) |
| Intended use | loopback, Docker test networks, networks the operator trusts; the stand-in for an LSP/1.0 peer in mixed-version tests | every real network; the only profile the app uses |

The plaintext profile IS the LSP/1.0 wire: a device in it behaves exactly like an Increment 1/2 device and keeps `v:"1.0"`. `kProtocolVersion` therefore stays `1.0`; a device in the secure profile reports `1.1` in `GET /info`, `SessionRequest.sender`, announces and `bye`. `kSupportedMajors` stays `["1"]`: a peer with any `1.x` is accepted by both profiles (4.6). The minor tells a peer which behaviour to expect, the capability tokens `sas` and `pair` (4.2 rule 11) which optional routes exist.

The secure profile never negotiates down: a client that requires TLS never retries over plain HTTP, and a TLS-only listener answers a plaintext request by closing the connection without an HTTP response (4.7).

**Transport.** TLS 1.3 is the minimum (no ALPN, HTTP/1.1, redirects are never followed). The server certificate is the device identity certificate: X.509 v3, self-signed, ECDSA P-256 with SHA-256, `CN` = deviceId, no subjectAltName (peers connect by IP address; the pin replaces name checks), BasicConstraints CA:false (critical), KeyUsage digitalSignature (critical), ExtendedKeyUsage serverAuth, valid from 24 h before creation for 3650 days. The certificate is created once with its key and never re-issued for the same key; pins ignore the validity dates. The **fingerprint** is the uppercase hex SHA-256 of the DER certificate (0.2). A client compares the fingerprint of the certificate received in the handshake with the pinned one before it sends any HTTP byte and aborts on a mismatch; with no pin it connects, learns the fingerprint and authenticates the server by SAS (5.1). The server does not request a client certificate (`dart:io` cannot accept a first-contact self-signed client certificate, ADR 0004): the sender is authenticated by the signed proof of 4.3.6.

## 4. Wire protocol

### 4.1 Defaults

| Item | Value | Constant (`protocol.dart`) | Marker |
|---|---|---|---|
| Protocol name / version | `libreshare` / `1.0` (`v` = major.minor); the plaintext profile | `kProtocolName`, `kProtocolVersion` | [I1] |
| Secure-profile version | `1.1`, reported in `/info`, `sender.v`, announces and `bye` by a device in the secure profile | `kProtocolVersionSecure` | [I3] |
| API prefix | `/api/v1` | `kApiPrefix` | [I1] |
| Multicast group | `224.0.0.168`, UDP `53318` (inside 224.0.0.0/24 because some Android devices reject other groups; avoids LocalSend's `.167:53317`) | `kMulticastGroup` | [I2] |
| HTTP(S) API port | TCP `53318`; fallback `53319`-`53327`; the actual port is announced | `kDefaultPort`, `kPortFallbackMax` | `ApiServer.start()` falls back to the next free port in [I1]; announcing it is [I2]; the Inc 1 CLI takes an explicit `--port` |
| mDNS | `_libreshare._tcp`, TXT keys `id`, `fp` (16 hex), `v`, `pf` | - | [I2] |
| TLS | TLS 1.3 only; server certificate = the device's self-signed ECDSA P-256 identity certificate, pinned by the client; the server never requests a client certificate; the sender proves its identity with `X-LS-Auth` (4.3.6) | - | [I3] |
| Fingerprint | uppercase hex SHA-256 of the DER certificate | - | [I3] |
| Chunk size | 4 MiB = 4,194,304 B | `kChunkSize` | [I1] |
| Chunk retries | 3 per chunk, back-off 0.5 s / 1 s / 2 s | `kChunkRetries` | [I1] |
| Permission timeout | 120 s with no decision -> `FAILED(TIMEOUT)` | `kPermissionTimeout` | [I3] |
| JSON body limit | 256 KiB (`262144` B) | `kMaxJsonBytes` | [I1] |
| JSON body limit, `POST /sessions`, secure profile | 4 MiB (4,194,304 B); 10,000 files of about 260 B fit. The plaintext profile keeps 256 KiB | `kMaxSessionJsonBytes` | [I3] |
| Files per session | at most 10,000 | `kMaxFilesPerSession` | [I1] |
| Chunk hash header | `X-LS-Chunk-SHA256` (mandatory in the secure profile [I3], optional in the plaintext profile) | `kChunkHashHeader` | [I1] |
| Identity-proof header | `X-LS-Auth` | `kAuthHeader` | [I3] |
| Proof timestamp window | +-120 s around the receiver's clock | `kAuthWindow` | [I3] |
| SAS reveal deadline | 30 s after the 202, else `FAILED(TIMEOUT)` | `kSasRevealTimeout` | [I3] |
| Pair request hold time | 125 s | `kPairTimeout` | [I3] |
| Session resumability | 24 h | - | [I4] |

### 4.2 Discovery announce  **[I2]**

Datagram: UDP JSON, at most **1200 bytes**, sent to `224.0.0.168:53318` (and as unicast replies). Schema: `schemas/discovery-announce.schema.json` (a `DeviceInfo` plus `announce`).

```json
{"proto":"libreshare","v":"1.0","deviceId":"uuid-v4","alias":"Ravi-ThinkPad",
 "platform":"windows","deviceType":"desktop","fingerprint":"64 hex","port":53318,
 "addrs":[{"ip":"192.168.1.23","if":"wifi"},{"ip":"10.0.0.5","if":"ethernet"}],
 "caps":["resume","tunnel","sas"],"announce":true}
```

[I3] In the secure profile `"v"` is `"1.1"`, `fingerprint` is the 64-hex fingerprint of the identity certificate and `caps` lists `sas` and `pair` (rule 11).

Rules:

1. A device announces at start, +1 s, +3 s, every 30 s, and on every network-interface change. A peer not heard from for **90 s** expires.
2. On receiving `announce:true` from a **foreign** fingerprint (and not from itself: filter own `deviceId`/fingerprint), the receiver replies with `POST https://<ip>:<port>/api/v1/register` carrying its own `DeviceInfo`. **[I3]** In the secure profile that request carries `X-LS-Auth` (4.3.6). If that request fails within **2 s**, it replies with a UDP unicast datagram with `announce:false`. A device that is itself not receiving (rule 8) neither registers nor replies. An `announce:true` from a peer that is already listed with the same fingerprint gets no reply at all (neither `/register` nor datagram). The `<port>` in the announcement and the `port` in every `DeviceInfo` a device emits (`GET /info`, `POST /register`, `SessionRequest.sender`, `libreshare://peer` links) is the port its listener is **actually bound to** after the 53318-53327 fallback, never the port it asked for; its `addrs` are the addresses it is reachable at now.
3. A receiver MUST silently drop datagrams that are not valid JSON, are larger than 1200 B, have `proto != "libreshare"`, or carry an unknown major `v`. It MUST rate-limit to **20 packets/s per source IP**.
4. **Subnet scan.** After 5 s with no peers, or on demand, `GET /api/v1/info` is issued across each local /24 (a network larger than /22 is skipped), 64 concurrent requests, 800 ms timeout each. This is the fallback when multicast is blocked.
5. **mDNS.** Service type `_libreshare._tcp`; TXT: `id` = deviceId, `fp` = first 16 hex of the fingerprint, `v` = protocol version, `pf` = platform.
6. **QR / manual.** `libreshare://peer?ip=<ip>&port=53318&fp=<64hex>&id=<uuid>&n=<alias>`. For manual IP entry the UI shows the peer's fingerprint for confirmation. This path handles access-point/client isolation. **[I3]** A second URI, `libreshare://pair?v=1&s=<32 B b64url>&id=<deviceId>&fp=<64 hex>&n=<alias>&ip=<ip>&port=<port>`, starts QR pairing (5.3). `s` is the 256-bit invite secret (43 base64url characters); it appears only in the QR code or in the invite text that is pasted, MUST NEVER be logged or sent over the network, and a `libreshare://peer` link never carries it. The member `r=` (relay hints) is reserved: Increment 6 adds it, it is not defined here. Unknown members MUST be ignored; an LSP/1.0 app does not know the `pair` path and ignores it.
7. Before Increment 3 no certificate exists, so announced `fingerprint` is the empty string; the schema permits that. **[I3]** In the secure profile it is the 64-hex fingerprint. An announcement whose fingerprint is empty, or differs from the one pinned for the same `deviceId`, never replaces or overrides the pinned device: an empty fingerprint marks a legacy peer (shown, not selectable as a secure send target, 4.7), a different one is a different, unverified device. "Never replaces" is literal: the registry entry of the pinned device (address, port, alias, fingerprint) stays exactly as it was; only an announcement with a DIFFERENT non-empty fingerprint raises the key-changed flag, an empty one raises nothing. An announcement carrying the pinned fingerprint updates the entry normally (so a new DHCP address is followed). Edge case: if the pinned device has no listed entry yet, an announcement with an empty fingerprint is listed WITH the pinned fingerprint (not as a legacy peer), and one with a different non-empty fingerprint creates an entry flagged key-changed.
8. **Send-only probe (`port: 0`).** A device that is not receiving (Receive mode Off: listener closed, nothing announced as receivable) MAY still look for peers so that its device list fills in about 1 s instead of waiting up to 30 s for their next announcement. It multicasts the normal datagram with `"announce":true` and `"port":0` at the schedule of rule 1. `port: 0` means "no listener here": a datagram with `port: 0` and `announce:false` is invalid and MUST be dropped. A receiver of a probe MUST NOT record the sender as a peer, MUST NOT `POST /register` to it (there is nothing to connect to) and MUST NOT offer it as a send target. If the receiver is itself receiving it SHOULD answer with a UDP unicast `announce:false` datagram (its real port) to the probe's source address and port, rate-limited like any datagram (rule 3); a receiver that is not receiving stays silent. A device that is not receiving still records the announcements and replies it hears, so it can list and send to receivable peers. Implementations that predate rule 8 drop a probe under rule 3 (their `port` check), which is harmless. A peer that stopped receiving simply stops being announced and expires after 90 s (rule 1); a secure-profile device additionally says goodbye with a signed `bye` datagram (rule 9) so that it disappears at once.
9. **Goodbye (`bye`) datagram [I3].** A secure-profile device whose listener closes, or whose Receive mode goes Off, multicasts this datagram twice, 50 ms apart:

   ```json
   {"proto":"libreshare","v":"1.1","t":"bye","deviceId":"uuid-v4","fingerprint":"64 hex","ts":1793793600000,"sig":"86 b64url"}
   ```

   Schema: the `bye` branch of `schemas/discovery-announce.schema.json` (about 290 B). `ts` is the sender's clock in Unix epoch milliseconds; `sig` is the raw ECDSA P-256 signature (r||s, base64url) over the signature domain `LSP1-BYE` (section 5, signature domains) followed by NUL and the text `deviceId` + `fingerprint` + `ts`, concatenated as UTF-8 without separators, `ts` as decimal digits. A receiver removes the peer from its device list (`PeerRegistry.remove`) only if ALL of: the datagram is a `bye` (`t` is `"bye"`, `v` is `1.1` or a later 1.x); `|now - ts| <= 60 s`; it holds the certificate whose SHA-256 is `fingerprint` (learned from a TLS handshake or a verified `X-LS-Auth` proof; without it the bye is ignored and the peer expires after 90 s as before); the signature verifies with that certificate's key; and `ts` is greater than that of every bye already accepted for the fingerprint (replay). A receiver spends at most 5 verifications per second across all sources (excess `bye` datagrams are dropped unverified) and applies the 20 packets/s per-source limit of rule 3 first. The peer must also currently be listed with that same fingerprint, otherwise the `bye` is ignored. A `bye` is never answered and never registers anything. It has no `alias` and no `announce` member, so an LSP/1.0 decoder drops it under rule 3 and the peer expires after 90 s as before.
10. **Contacts-only replies [I3].** A receiver whose visibility is Contacts-only (5.4) multicasts nothing of its own: no announcement of any kind (no start burst, no periodic schedule, no `announceNow`, no probe) and no mDNS service. It still listens: it hears other devices' announcements and answers contacts as follows, and it can find peers by the HTTPS scan with an `X-LS-Auth` proof or by a pairing/manual address. It answers an `announce:true` probe with a unicast `announce:false` only if the probe carries a non-empty fingerprint that belongs to a contact. Best effort: the fingerprint claim is not authenticated (5.4). Its HTTPS listener stays bound and treats strangers as in 4.3.2.
11. **Capability tokens [I3].** `caps` is an open set; unknown tokens are ignored (0.2). Defined: `resume` (`GET .../state` resync), `tunnel` (reserved for [I5]), `sas` (the device serves `POST /sessions/{sid}/sas` and answers a `sasCommit` with `sas.nonce`), `pair` (the device serves `POST /pair`). The token `sas` already appears in LSP/1.0 examples without behaviour; it acquires its meaning in the secure profile, where `sas` and `pair` are advertised. A sender SHOULD NOT call `/sas` or `/pair` on a peer that does not list the token (an LSP/1.0 peer answers 404).

### 4.3 REST API

Base URL: `https://<host>:<port>/api/v1` over TLS 1.3 with a pinned server certificate and a signed client proof **[I3]** (the secure profile, 0.3); `http://<host>:<port>/api/v1` in the plaintext profile **[I1]**. Only one party (the receiver) needs a server for local tiers.

#### 4.3.1 Headers and authentication

| Header | Direction | Used on | Rules |
|---|---|---|---|
| `Content-Type: application/json` | both | all JSON bodies | UTF-8. |
| `Content-Type: application/octet-stream` | request | chunk PUT | Raw bytes of exactly one chunk. |
| `Content-Length` | request | chunk PUT | MUST be present and equal the chunk length (`PeerClient.putChunk(length:)`). A chunk PUT without `Content-Length` (chunked transfer encoding) -> 400 BAD_REQUEST; an absurd declared length (far above one chunk) -> 413 TOO_LARGE without reading the body. |
| `Authorization: Bearer <fileToken>` | request | `GET .../state`, `PUT .../chunks/{idx}`, `POST .../complete` | `fileToken` is the 128-bit per-file token from `SessionStatus.acceptedFiles[fid].token`. Missing, malformed, unknown or wrong-file/wrong-session token -> `401 TOKEN_INVALID`. Compared in constant time. |
| `X-LS-Chunk-SHA256: <64 lowercase hex>` | request | chunk PUT | SHA-256 of the chunk body. A value that is not 64 hex characters -> 400 BAD_REQUEST. Mandatory in the secure profile **[I3]** (missing -> 400 BAD_REQUEST), optional in the plaintext profile. See 4.3.4. |
| `X-LS-Auth: v1.<cert>.<ts>.<nonce>.<sig>` | request | `POST /sessions`, `POST /register`, `POST /pair`, `POST /sessions/{sid}/sas`; `GET /info` of a Contacts-only receiver **[I3]** | Signed identity proof, at most 4 KiB; grammar, signed text and checks in 4.3.6. Missing or invalid -> 401 AUTH_INVALID (a Contacts-only stranger gets the plain 404). Secure profile only; a plaintext server ignores it. |
| `Retry-After: <seconds>` | response | any 429; a 403 BLOCKED caused by a PIN-failure window **[I3]** | Whole seconds until a retry can succeed. Values: a PIN-failure `BLOCKED` is the remaining window rounded up, at least 1; the `POST /sessions` rate limit is the time until a token is available rounded up to whole seconds, at least 1; the oversize-body 429 is a fixed 5; the pending-prompt 429 is a fixed 30. |
| `Date` | response | all responses **[I3]** | The server's clock (HTTP-date). A client whose proof was refused as stale corrects its clock from it and retries once (4.3.6). |
| `Cache-Control: no-store` | response | all JSON responses | Responses are never cacheable. Servers do not advertise their framework (no `X-Powered-By`). |

Authentication layers:

- **Channel** [I3]: TLS 1.3. The client authenticates the server by pinning its certificate fingerprint (first contact: the SAS of 5.1); the server does not request a client certificate. Session-level endpoints (`/sessions/{sid}`, `/finish`, `/cancel`) rely on the channel plus the unguessable `sessionId`. In the plaintext profile ([I1]) there is no channel authentication.
- **Identity proof** [I3]: the sender authenticates itself with `X-LS-Auth` on the routes listed in 4.3.6. The proof is bound to the request (method, target, body hash), to a fresh nonce and clock, and to the server fingerprint the client saw in the TLS handshake.
- **File token** [I1]: the Bearer token guards the three file-level endpoints. The spec endpoint table lists `Authorization` only on the chunk PUT; the Dart contracts (`IncomingTransferHandler.fileState/putChunk/completeFile` all take `token`) require it on `state` and `complete` as well, and this document follows the code.
- Tokens are issued when the session leaves `PENDING`, are bound to `(sessionId, fileId)`, and die with the session (COMPLETED, FAILED, cancel). A sender that lost its tokens (reconnect, receiver restart) obtains the current tokens and `receivedRanges` again from `GET /sessions/{sid}`.

#### 4.3.2 Endpoints

| Method and path | Purpose | Auth | Success | Errors | Marker |
|---|---|---|---|---|---|
| `GET /info` | identify peer | - ; `X-LS-Auth` on a Contacts-only receiver **[I3]** | 200 `DeviceInfo` | 404 NOT_FOUND (Contacts-only receiver, stranger) | [I1] (Contacts-only [I3]) |
| `POST /register` | two-way discovery | `X-LS-Auth` **[I3]** | 200 `DeviceInfo` (receiver's own) | 400 BAD_REQUEST, 401 AUTH_INVALID, 404 NOT_FOUND (Contacts-only receiver, stranger), 426 UPGRADE_REQUIRED | route [I1], used by discovery [I2], proof [I3] |
| `POST /sessions` | permission request (FR-05/06/07) | channel; `X-LS-Auth` **[I3]** | 202 `SessionStatus{PENDING}`, or 200 `SessionStatus{IN_PROGRESS}` on auto-accept | 400 BAD_REQUEST, 401 AUTH_INVALID/PIN_REQUIRED/PIN_INVALID, 403 BLOCKED/KEY_CHANGED, 404 NOT_FOUND (Contacts-only receiver, stranger), 409 BUSY, 413 TOO_LARGE, 426 UPGRADE_REQUIRED, 429 RATE_LIMITED, 507 INSUFFICIENT_STORAGE | [I1] (AUTH_INVALID/KEY_CHANGED/PIN/BLOCKED/404/507 [I3]) |
| `GET /sessions/{sid}?wait=N` | long-poll status | channel | 200 `SessionStatus` | 400 BAD_REQUEST, 404 NOT_FOUND, 410 CANCELLED | [I1] |
| `GET /sessions/{sid}/files/{fid}/state` | resume bitmap | Bearer | 200 `FileState` | 401 TOKEN_INVALID, 404 NOT_FOUND, 409 WRONG_STATE, 410 CANCELLED | [I1] |
| `PUT /sessions/{sid}/files/{fid}/chunks/{idx}` | upload one chunk (FR-08) | Bearer + hash header | 200 `{"ack":true,"index":<idx>}` (idempotent) | 400 BAD_REQUEST, 401 TOKEN_INVALID, 404 NOT_FOUND, 409 WRONG_STATE, 410 CANCELLED, 413 TOO_LARGE, 416 OUT_OF_RANGE, 422 CHUNK_HASH_MISMATCH | [I1] |
| `POST /sessions/{sid}/files/{fid}/complete` | verify file (FR-09/10) | Bearer | 200 `FileVerification` | 400 BAD_REQUEST, 401 TOKEN_INVALID, 404 NOT_FOUND, 409 MISSING_CHUNKS/WRONG_STATE, 410 CANCELLED, 413 TOO_LARGE, 422 VERIFY_FAILED | [I1] |
| `POST /sessions/{sid}/finish` | close session (FR-11) | channel | 200 `SessionStatus{COMPLETED}` | 404 NOT_FOUND, 409 WRONG_STATE, 410 CANCELLED | [I1] |
| `POST /sessions/{sid}/cancel` | cancel | channel | 200 (body informational) | 404 NOT_FOUND | [I1] |
| `POST /sessions/{sid}/sas` | reveal the sender's SAS nonce (5.1) | channel; `X-LS-Auth` | 200 `SessionStatus{PENDING}` | 400 BAD_REQUEST, 401 AUTH_INVALID, 404 NOT_FOUND, 409 WRONG_STATE, 410 CANCELLED | [I3] |
| `POST /pair` | QR pairing (5.3), held up to 125 s | `X-LS-Auth`; `mac` over the invite secret | 200 `PairResponse` | 400 BAD_REQUEST, 401 AUTH_INVALID, 403 BLOCKED/KEY_CHANGED, 404 NOT_FOUND, 409 BUSY, 413 TOO_LARGE, 426 UPGRADE_REQUIRED, 429 RATE_LIMITED | [I3] |

Rules that apply to every `/sessions/{sid}/...` endpoint (including `/sas`): unknown `sid` or `fid` -> 404 NOT_FOUND; a cancelled session -> 410 CANCELLED; an operation that the session's current state does not permit -> 409 WRONG_STATE. Path parameters are percent-decoded; an invalid percent-encoding -> 400 BAD_REQUEST.

**[I3]** Contacts-only (5.4): a receiver in that visibility answers a stranger on `GET /info`, `POST /register` and `POST /sessions` with the 404 NOT_FOUND envelope of an unknown route, byte for byte (no new error code, no oracle). In the plaintext profile `/sessions/{sid}/sas` and `/pair` do not exist and fall under the routing rule below.

Routing: any path that is not one of the routes above, any path outside `/api/v1`, and any **known path with the wrong HTTP method** (e.g. `DELETE /info`, `GET .../cancel`) -> 404 NOT_FOUND with the standard envelope (there is no 405). A path under another major (`/api/v2/...`) is simply unknown to a v1 server and also yields 404; major mismatch is signalled through `v` (4.6). An unexpected server fault -> 500 INTERNAL with a generic message that leaks no paths, tokens or exception text.

#### 4.3.3 Payloads

All DTOs are defined by the schemas; the Dart classes in `lib/src/model/` serialise exactly these shapes.

| Payload | Schema | Dart type |
|---|---|---|
| DeviceInfo | `schemas/device-info.schema.json` | `DeviceInfo` (+ `DeviceAddress`) |
| FileItem | `schemas/file-item.schema.json` | `FileItem` |
| SessionRequest | `schemas/session-request.schema.json` | `SessionRequest` |
| TunnelOffer | `schemas/tunnel-offer.schema.json` | `TunnelOffer` |
| SessionStatus | `schemas/session-status.schema.json` | `SessionStatus` + `AcceptedFile` |
| FileState | `schemas/file-state.schema.json` | `FileState` |
| FileVerification | `schemas/file-verification.schema.json` | `FileVerification` |
| ErrorEnvelope | `schemas/error-envelope.schema.json` | `LsException.toEnvelope()` |
| DiscoveryAnnounce (announce, and the `bye` branch [I3]) | `schemas/discovery-announce.schema.json` | `DeviceInfo.toJson()` + `announce` |
| SasChallenge (`SessionStatus.sas`) [I3] | `schemas/session-status.schema.json` (`$defs/sasChallenge`) | `SasChallenge` |
| SasReveal (body of `POST .../sas`) [I3] | `schemas/lsp11/sas-reveal.schema.json` | `SasChallenge` (same shape) |
| PairRequest [I3] | `schemas/lsp11/pair-request.schema.json` | `PairRequest` |
| PairResponse [I3] | `schemas/lsp11/pair-response.schema.json` | `PairResponse` |
| AuthProof (decoded `X-LS-Auth`) [I3] | `schemas/lsp11/auth-proof.schema.json` | - |

```json
// SessionRequest (POST /sessions)
{"sender":{"...":"DeviceInfo"},"pin":"123456","chunkSize":4194304,
 "files":[{"fileId":"f1","fileName":"report.pdf","relativePath":null,"size":5242880000,
   "mime":"application/pdf","sha256":"<64 lowercase hex or null>","chunkCount":1250,"modified":"2026-10-30T10:00:00Z"}],
 "totalSize":5242880000,
 "tunnelOffer":{"provider":"cloudflare-quick","url":"https://x.trycloudflare.com/t/<token>",
   "keyB64":"<32 bytes b64url>","expiresAt":"2026-11-02T12:30:00Z"},
 "sasCommit":"<43 chars b64url, [I3], only when the sender cannot authenticate the receiver>"}

// SessionStatus
{"sessionId":"uuid","status":"PENDING|IN_PROGRESS|COMPLETED|FAILED","failureReason":null,
 "acceptedFiles":{"f1":{"token":"b64url-128bit","receivedRanges":[]}},
 "sas":{"nonce":"<22 chars b64url, [I3], while a SAS comparison is pending>"}}

// POST /sessions/{sid}/sas request body [I3]
{"nonce":"<22 chars b64url>"}

// POST /pair request / 200 response [I3]
{"sender":{"...":"DeviceInfo"},"nonce":"<22 chars b64url>","mac":"<43 chars b64url>"}
{"accepted":true,"responder":{"...":"DeviceInfo"},"nonce":"<22 chars b64url>","mac":"<43 chars b64url>"}

// FileState (GET .../state)
{"receivedRanges":[[0,41]],"chunkCount":1250}

// FileVerification (POST .../complete -> 200)
{"verified":true,"sha256":"<64 lowercase hex>"}

// POST .../complete request body (only required when the manifest sha256 was null)
{"sha256":"<64 lowercase hex>"}
```

Notes:

- `TransferStatus` has exactly four values, `PENDING`, `IN_PROGRESS`, `COMPLETED`, `FAILED`. Failure causes are in `failureReason` (`REJECTED`, `TIMEOUT`, `CANCELLED`, `VERIFY_FAILED`, `NO_CONNECTION`, `DISK_FULL`, `PROTOCOL_ERROR`); a `FAILED` status SHOULD carry a non-null `failureReason`.
- `DeviceInfo.port` is the TCP port of the sender's own API listener, **as actually bound** (after the port fallback of 4.1; `GET /info` MUST NOT return the requested port when another was bound) [I2]; a send-only client (the Increment 1 `ls send` / `ls info`, which start no server, or an engine whose Receive mode is Off) reports `0`. Discovery announcements ([I2]) carry a real port (`>= 1`), except the send-only probe of 4.2 rule 8, which carries `0` together with `announce:true` (`discovery-announce.schema.json` enforces both).
- `tunnelOffer` travels only inside the authenticated channel so the tunnel provider never learns `keyB64`.
- The whole-file SHA-256 is computed in a background isolate, pipelined with sending. For files **larger than 2 GiB** the manifest carries `sha256: null` and the sender supplies the value in the body of `POST .../complete` once hashing finishes. If both manifest and body carry a value they MUST be equal; a receiver rejects a disagreement with 400 BAD_REQUEST. If neither carries one -> 400 BAD_REQUEST.
- The `{"ack":true,"index":<idx>}` body of a successful chunk PUT is informational (`ack` is always `true`). **The ack is the HTTP 200 status** (spec 4.4); clients MUST NOT depend on the body.

#### 4.3.4 Endpoint behaviour

**`POST /sessions`.** Checks run in this order (the plaintext profile; the secure-profile order is given below the list); the first failure rejects the request and no session is created:

1. [I1] Rate limit: 10 requests per minute per remote IP (token bucket, burst 10, refilling continuously) -> 429 RATE_LIMITED with `Retry-After`. The check happens **before** the body is read or parsed. Only `POST /sessions` is limited.
2. [I1] Body size: more than 256 KiB (262,144 B; exactly 256 KiB is accepted, one byte more is not) -> 413 TOO_LARGE, enforced also for chunked bodies and without reading an oversized declared `Content-Length`. More than 10,000 files -> 413 TOO_LARGE. **[I3]** In the secure profile the limit of this route is 4 MiB (4,194,304 B, `kMaxSessionJsonBytes`; 10,000 files of about 260 B fit); a body above 256 KiB needs a `Content-Length` (a body without one is cut off at 256 KiB), and at most 2 such oversize bodies are read at the same time (a third is refused with 429 RATE_LIMITED, retryable). Every other route keeps 256 KiB. The plaintext profile keeps 256 KiB for this route too, so it carries only about 1,000 files.
3. [I1] Syntax and shape: invalid JSON or non-UTF-8, top-level not an object, `sender`/`files`/`totalSize` missing or of the wrong type, `modified` not a date, `caps` not strings -> 400 BAD_REQUEST.
4. [I1] Version: major of `sender.v` not in `{1}` -> 426 UPGRADE_REQUIRED (4.6). The major is read first, so a future-shaped body is answered with 426 rather than 400.
5. [I1] Consistency: `chunkSize <= 0`, any `size < 0`, `sum(size) != totalSize` -> 400 BAD_REQUEST. The handler (receiver) additionally rejects a `chunkSize` that is not a power of two between 65,536 (64 KiB) and 16,777,216 (16 MiB), `chunkCount != ceil(size / chunkSize)`, an empty or duplicate `fileId`, and an empty `files` list with 400 BAD_REQUEST, and unsafe `relativePath` values (section 5).
6. [I3] Block list -> 403 BLOCKED; PIN -> 401 PIN_REQUIRED / PIN_INVALID; free space below `totalSize + 64 MiB` -> 507 INSUFFICIENT_STORAGE; at most 3 pending prompts per IP and 8 in total -> 429 RATE_LIMITED.
7. A receiver already servicing its maximum number of sessions (in the plaintext profile this check is made BEFORE the syntax and validation checks above, as in Increments 1 and 2; the secure profile order below puts it last), or one whose Receive window has ended while earlier transfers are still running (it no longer takes new sessions and closes its listener when they finish or after 5 minutes) [I2] -> 409 BUSY (retryable).

Outcomes: `202` with `SessionStatus{PENDING, acceptedFiles:{}}` while a human decides; `200` with `SessionStatus{IN_PROGRESS}` including `acceptedFiles` (one token per `fileId`) when the receiver auto-accepts (trusted sender opt-in, or `--auto-accept`). The HTTP status is 202 exactly when the returned status is `PENDING`. The receiver chooses `sessionId` (random, unguessable). **[I3]** A request that carries `sasCommit` is never auto-accepted, whatever the sender's trust level (5.1).

**Secure-profile order [I3].** In the secure profile the first failure still rejects the request and no session is created, but the checks run in this order:

1. **gate** - only on a Contacts-only receiver (5.4): a request without a well-formed `X-LS-Auth`, or whose certificate fingerprint is not a contact, -> 404 NOT_FOUND, the envelope of an unknown route. Nothing of the body has been read yet. The PIN-failure block is NOT a pre-body gate: it is consulted at step 10.
2. **rate limit** - 10 requests per minute per IP -> 429 RATE_LIMITED with `Retry-After`; before the body is read.
3. **body size** - more than 4 MiB (or more than 256 KiB without `Content-Length`) -> 413 TOO_LARGE. This is the only size check before authentication; the 10,000-file limit is decided after the proof verified (see below the list).
4. **auth** - `X-LS-Auth` absent, malformed, stale, replayed, forged or naming another server -> 401 AUTH_INVALID (4.3.6). An unauthenticated body that is invalid JSON or lists more than 10,000 files therefore also gets 401.
5. **shape** - invalid JSON or UTF-8, wrong member types, a `sasCommit` that is not 43 base64url characters -> 400 BAD_REQUEST (step 3 of the list above); then more than 10,000 files -> 413 TOO_LARGE. A `pin` that is present but not exactly six ASCII digits is also a shape error: 400 BAD_REQUEST, never a strike.
6. **version** - major of `sender.v` not 1 -> 426 UPGRADE_REQUIRED (step 4 above). The major is checked before the `sasCommit` format, so a body with both faults gets 426, not 400.
7. **consistency** - sizes, chunk counts, ids -> 400 BAD_REQUEST (step 5 above). Unsafe `relativePath` values are not decided here (see below the list).
8. **sender match** - `sender.fingerprint` empty or different from the fingerprint the proof names, or the certificate's `CN` different from `sender.deviceId` -> 401 AUTH_INVALID.
9. **trust** - a blocked fingerprint -> 403 BLOCKED; a known `deviceId` whose pinned fingerprint differs from the proven one -> 403 KEY_CHANGED (never auto-accepted, even for a trusted contact).
10. **pin** - the PIN-failure block is consulted here: a source IP inside a block window, or PIN checks locked, -> 403 BLOCKED with `Retry-After` (5.2), and a PIN-less request from a blocked source gets BLOCKED rather than PIN_REQUIRED. Otherwise a PIN is required and absent -> 401 PIN_REQUIRED; wrong, expired or consumed -> 401 PIN_INVALID. Trusted contacts that the policy exempts skip this step entirely, so a contact behind the same NAT as an attacker still works.
11. **storage** - free space below `totalSize + 64 MiB`, or a download folder that does not exist and cannot be created, or is not writable -> 507 INSUFFICIENT_STORAGE (decided 2026-11-05 after the Android emulator run: the unusable folder used to surface late as PROTOCOL_ERROR; this applies to both profiles).
12. **pending** - the IP already has 3 pending prompts (3 per IP) or 8 are pending in total -> 429 RATE_LIMITED with `Retry-After`.
13. **busy** - maximum sessions reached, or the Receive window ended while transfers run -> 409 BUSY (step 7 above).

After step 13 the session is opened. An unsafe `relativePath` (a `..` segment or an unrepresentable name, section 5) -> 400 BAD_REQUEST is decided at that point, that is AFTER the PIN, storage, pending-cap and busy checks, but always before the user is asked. A request with an unsafe path and a missing PIN therefore gets 401 PIN_REQUIRED, and one sent to a busy receiver gets 409. The one-time PIN is consumed atomically at the moment the session is registered: a request refused at storage, pending or busy does not burn it. Once the session is open and the sender is a contact the policy lets through, the handling follows 5.1.


**`GET /sessions/{sid}?wait=N`.** `wait` is a whole number of seconds (default 0; the reference client sends 25). A non-integer value (`abc`, `1.5`, empty) -> 400 BAD_REQUEST; the server clamps the value to the range 0..25 (negative becomes 0, anything above 25 becomes 25). If the session is already past `PENDING` the response is immediate. While `PENDING`, the server holds the request until the status changes or `wait` seconds elapse, then returns the current `SessionStatus` (still `PENDING` on a timeout). The client loops. When accepted the response carries `IN_PROGRESS` plus `acceptedFiles` (tokens, current `receivedRanges`). On reject: `200` with `FAILED` / `REJECTED`; on 120 s silence: `200` with `FAILED` / `TIMEOUT` [I3]. A cancelled session answers 410 CANCELLED - both when the handler raises it and when the session reports `FAILED(CANCELLED)`; a `FAILED` status with any other reason is an ordinary 200.

**`GET .../files/{fid}/state`.** Returns the chunks durably received so far as inclusive ranges, plus `chunkCount`. Idempotent and side-effect free.

**`PUT .../chunks/{idx}`.**

1. HTTP layer [I1]: `idx` must be an integer (non-integer or overflowing -> 400 BAD_REQUEST; negative -> 416 OUT_OF_RANGE); `Authorization: Bearer` must be present (else 401 TOKEN_INVALID); `Content-Length` must be present (400); `X-LS-Chunk-SHA256`, if present, must be 64 hex characters (400) and is lowercased before it reaches the handler.
2. Session MUST be `IN_PROGRESS` (else 409 WRONG_STATE); token MUST match the file (else 401).
3. `idx` MUST satisfy `0 <= idx < chunkCount` (else 416 OUT_OF_RANGE). A 0-byte file has no valid `idx`.
4. The body length MUST equal the length of chunk `idx` (`min(chunkSize, size - idx*chunkSize)`). A longer body is "a write past the declared size" -> 416 OUT_OF_RANGE (the server stops reading). A shorter body -> 400 BAD_REQUEST. Neither may corrupt previously received data.
5. The receiver computes SHA-256 over the received body and compares it with `X-LS-Chunk-SHA256`. A mismatch -> **422 CHUNK_HASH_MISMATCH** (retryable): the chunk is NOT recorded as received and previously acknowledged bytes are NOT disturbed (verify before writing at the chunk's offset; a chunk is at most 4 MiB, so buffering one chunk is acceptable).
6. On success the chunk is written at `idx * chunkSize` (64-bit offset) in `<name>.lspart`, marked received, and `200 {"ack":true,"index":<idx>}` is returned. Re-sending an already received chunk with a valid hash is **idempotent** and also returns 200.
7. The sender MUST send `X-LS-Chunk-SHA256` on every chunk (`PeerClient.putChunk` requires it). The HTTP layer treats the header as optional and hands `null` to `IncomingTransferHandler.putChunk(chunkSha256: null)`; a receiver MUST verify the hash whenever it is present, and an Increment 1 receiver MAY accept an unhashed chunk (whole-file verification still applies). **[I3]** In the secure profile a missing header is a 400 BAD_REQUEST, enforced by the HTTP layer before the handler is called. The plaintext profile keeps treating it as optional, so that the Increment 1 conformance stays valid.
8. The handler may abort while the body is still arriving (hash failure, out-of-range, wrong token); the server then answers with the error envelope promptly and keeps serving other requests. A client that disconnects mid-body does not affect the server.

**`POST .../files/{fid}/complete`.**

0. The optional JSON body is `{"sha256":"<64 hex>"}`. An absent body, `{}`, or `{"sha256":null}` means "none"; malformed JSON, a non-object, or a `sha256` that is not 64 hex characters -> 400 BAD_REQUEST; a body over 256 KiB -> 413 TOO_LARGE. Uppercase hex is accepted and lowercased. Unknown members are ignored.
1. If any chunk in `[0, chunkCount)` is missing -> 409 MISSING_CHUNKS (retryable; the sender calls `/state` and resends the gap).
2. The receiver computes the SHA-256 of the reassembled `.lspart` and compares it with the manifest value (or the request body value when the manifest had `null`).
3. Mismatch -> **422 VERIFY_FAILED**: the partial file is deleted (unless "keep partial files" is on), the session becomes `FAILED(VERIFY_FAILED)`.
4. Match -> atomic save: verify, rename `<name>.lspart` to the final sanitized name, set mtime from `modified`, emit `FileSaved`; respond `200 FileVerification{verified:true, sha256}`. Calling `complete` again on an already verified file returns the same 200.
5. A 0-byte file (`chunkCount` 0) is completed with no chunk PUTs; the receiver creates an empty file; `sha256` is the empty-input digest `e3b0c442...b855`.

**`POST /sessions/{sid}/finish`.** If every file in the session has been verified: session -> `COMPLETED`, `200 SessionStatus{COMPLETED}`. Otherwise 409 WRONG_STATE. Idempotent after completion. Both sides then report success (FR-11). Request bodies on `finish` and `cancel` are ignored (and drained).

**`POST /sessions/{sid}/cancel`.** The session becomes `FAILED(CANCELLED)`; partial files are deleted unless "keep partial files" is on. Any later call by the peer on that session gets 410 CANCELLED. Cancelling an already-terminal session is a no-op returning 200.

**`POST /sessions/{sid}/sas` [I3].** Body `{"nonce":"<22 b64url>"}` (`schemas/lsp11/sas-reveal.schema.json`); `X-LS-Auth` required, and the fingerprint the proof names MUST be the session's sender (else 401 AUTH_INVALID). Valid only once, on a session that is `PENDING`, was created with a `sasCommit` and whose reveal deadline (30 s after the 202, `kSasRevealTimeout`) has not passed. The receiver recomputes the commitment of 5.1 from the revealed nonce, the proven sender fingerprint and its own fingerprint, and compares it with `sasCommit` in constant time. Match -> 200 `SessionStatus{PENDING}` whose `sas.nonce` is unchanged; the receiver derives the code and may now enable Accept. Mismatch -> 401 AUTH_INVALID and the session becomes `FAILED(PROTOCOL_ERROR)`: a relaying man-in-the-middle fails here without any human comparison. A second call, a session without `sasCommit`, or a terminal session -> 409 WRONG_STATE; unknown `sid` -> 404 NOT_FOUND; cancelled -> 410 CANCELLED; a body that is not a 22-character base64url nonce -> 400 BAD_REQUEST. If no reveal arrives in time the session becomes `FAILED(TIMEOUT)` and the sender's next `GET /sessions/{sid}` reports it. Order: rate limit and size, `X-LS-Auth`, the nonce format (400, decided before the session lookup), session lookup (404), then the proof binding: a proof from a fingerprint other than the session's sender gets 401 AUTH_INVALID WITHOUT failing the session (a foreigner cannot kill a session), and only after that the state checks 410 / 409 and the commitment comparison.

**`POST /pair` [I3].** Body `PairRequest` (`schemas/lsp11/pair-request.schema.json`); `X-LS-Auth` required, and `sender.fingerprint` MUST equal the fingerprint the proof names. The route exists only while the receiver has an active pairing invite (5.3: created by its user, valid 10 min, single use); without one it answers 404 NOT_FOUND, indistinguishable from an unknown route for a caller that holds a valid proof. The 404 is decided only after the rate limit, the size check and a valid proof: an unauthenticated caller sees 401 AUTH_INVALID, not 404. This holds for a Contacts-only receiver too: pairing is exempt from the Contacts-only gate because the invite secret authenticates the caller. The checks run in this order: rate limit (the bucket of `POST /sessions`, 429), body size (256 KiB, 413), `X-LS-Auth` (401 AUTH_INVALID), no active invite (404), shape (400, which includes decoding `nonce` and `mac`: this precedes the version check), version (426), `sender.fingerprint` equals the proof and the certificate `CN` equals `sender.deviceId` (401 AUTH_INVALID), `mac` verifies against the invite secret `S` in constant time (401 AUTH_INVALID; a wrong `mac` does not consume the invite), a blocked sender fingerprint (403 BLOCKED) or a known `deviceId` with a different pinned fingerprint (403 KEY_CHANGED), and finally at most one request is held at a time (another gets 409 BUSY). The accepted request is then held open until the inviter's user decides, for at most `kPairTimeout` (125 s). Accept -> 200 `PairResponse{accepted:true}`; decline or timeout -> 200 `PairResponse{accepted:false}`. Either outcome spends the invite. On accept both sides pin each other as `trusted` contacts and derive `K_pair` locally (5.3). If storing the contact fails on the inviter, it answers `PairResponse{accepted:false}`.

#### 4.3.5 Error envelope and codes

Every non-2xx response has `Content-Type: application/json` and this body (schema `error-envelope.schema.json`):

```json
{"error":{"code":"CHUNK_HASH_MISMATCH","message":"...","retryable":true}}
```

`code` is the wire string of `LsErrorCode`; the HTTP status of each code is fixed, and `ApiServer` maps an `LsException` thrown by the handler to exactly that status on every route. The 426 response additionally carries a top-level `supported` member (see 4.6). `message` is a diagnostic and MUST NOT contain file contents, keys, PINs or tunnel URL fragments. A client maps an unrecognised `code` to `INTERNAL`. `LsException.code`, `.httpStatus` and `.retryable` are derived from this table (`lib/src/model/ls_exception.dart`); `test/conformance/api_conformance_test.dart` asserts, for every route and every `LsErrorCode`, the status, `application/json` content type, `code`, `message` and `retryable`.

| Code | HTTP | Retryable | Meaning | Enforced from |
|---|---|---|---|---|
| `BAD_REQUEST` | 400 | no | Malformed JSON, missing/invalid member, size or count inconsistency, bad header. | [I1] |
| `AUTH_INVALID` | 401 | no | The `X-LS-Auth` identity proof is missing, malformed, stale, replayed, forged, or names a different server than the one reached; `sender.fingerprint` or the certificate `CN` differs from the sender's claim (`deviceId`); a revealed SAS nonce does not match the commitment; the pairing `mac` is wrong. LSP/1.1 secure profile only. | [I3] |
| `KEY_CHANGED` | 403 | no | A known `deviceId` presented a different certificate than the one pinned for it. LSP/1.1 secure profile only. | [I3] |
| `PIN_REQUIRED` | 401 | no | Receiver demands a PIN and none was sent. | [I3] |
| `PIN_INVALID` | 401 | no | Wrong, expired or already used PIN, answered identically (5 failures per IP -> 10 min block). | [I3] |
| `TOKEN_INVALID` | 401 | no | Missing/invalid/mismatched `Authorization: Bearer` file token. | [I1] |
| `BLOCKED` | 403 | no | Sender is on the block list, is in a PIN-failure block window, or PIN checks are locked after repeated failures from many sources; `Retry-After` is set for the windows. | [I3] |
| `NOT_FOUND` | 404 | no | Unknown route, session or file id. [I3] Also the answer of a Contacts-only receiver to a stranger, and of `POST /pair` without an active invite: the envelope of an unknown route, no new code. | [I1] |
| `BUSY` | 409 | yes | Receiver cannot take another session right now. | [I1] |
| `WRONG_STATE` | 409 | no | Operation not valid in the session's current state (chunk before accept, `finish` with unverified files). | [I1] |
| `MISSING_CHUNKS` | 409 | yes | `complete` called while chunks are missing. | [I1] |
| `CANCELLED` | 410 | no | Session was cancelled; sender maps to `FAILED(CANCELLED)`. | [I1] |
| `TOO_LARGE` | 413 | no | Body > 256 KiB (> 4 MiB for `POST /sessions` in the secure profile [I3]), > 10,000 files, or total above receiver limit. | [I1] |
| `OUT_OF_RANGE` | 416 | no | Chunk index outside `[0, chunkCount)` or body longer than the declared chunk. | [I1] |
| `CHUNK_HASH_MISMATCH` | 422 | yes | Chunk body SHA-256 differs from `X-LS-Chunk-SHA256`; resend. | [I1] |
| `VERIFY_FAILED` | 422 | no | Whole-file SHA-256 mismatch; session fails. | [I1] |
| `UPGRADE_REQUIRED` | 426 | no | Incompatible protocol major in `sender.v`; the envelope also carries a top-level `supported:["1"]`. | [I1] |
| `RATE_LIMITED` | 429 | yes | Per-IP rate limit exceeded (10 `POST /sessions`/min in [I1]; pending-prompt caps of 3 per IP and 8 in total, and the oversize-body cap [I3]); `Retry-After` header set. | [I1] |
| `INTERNAL` | 500 | yes | Unexpected receiver error (also the client-side fallback for unknown codes). | [I1] |
| `INSUFFICIENT_STORAGE` | 507 | no | Free space below `totalSize + 64 MiB`, or the download folder is missing and cannot be created, or is not writable. | [I3] |

Recommended client mapping to `FailureReason`: `CANCELLED` -> `CANCELLED`; `VERIFY_FAILED` -> `VERIFY_FAILED`; `INSUFFICIENT_STORAGE` -> `DISK_FULL`; channel exhaustion -> `NO_CONNECTION`; any other non-retryable error -> `PROTOCOL_ERROR`. `REJECTED` and `TIMEOUT` arrive as `SessionStatus.failureReason`, not as HTTP errors. **[I3]** `AUTH_INVALID` maps to `PROTOCOL_ERROR` unless the client has a better local classification; a pin mismatch (`PeerKeyChanged`) or a legacy peer (`InsecurePeer`) is detected by the sender before any request and is not a wire error.

#### 4.3.6 Identity proof: `X-LS-Auth`  **[I3]**

TLS authenticates the receiver to the sender (by pin or SAS). The sender authenticates itself per request with an ECDSA P-256 signature in the `X-LS-Auth` header (`kAuthHeader`). The proof covers the request, a clock value, a fresh nonce and BOTH fingerprints. It cannot be reused for another request, cannot be replayed to another server (channel binding: a relaying man-in-the-middle terminates TLS with its own certificate, so the proof the sender signs names the wrong server fingerprint and the real receiver rejects it) and cannot be replayed to the same server (nonce cache). A valid proof says only that the holder of this key sent this request; whether the key is trusted is decided by the trust store (blocked, KEY_CHANGED, SAS, contacts).

**Grammar.** The header value has the form `v1.<cert>.<ts>.<nonce>.<sig>` (text form: `$defs/header` of `schemas/lsp11/auth-proof.schema.json`; decoded members: the schema root):

```
x-ls-auth = "v1" "." cert "." ts "." nonce "." sig
cert      = 1*2731 b64url                ; DER of the sender's identity certificate, at most 2048 bytes
ts        = "0" / ( %x31-39 0*15DIGIT )  ; Unix epoch milliseconds, decimal, no leading zeros
nonce     = 22 b64url                    ; 16 random bytes
sig       = 86 b64url                    ; ECDSA P-256 over the signed text, raw r||s, 64 bytes
b64url    = ALPHA / DIGIT / "-" / "_"    ; unpadded and canonical
```

The value is at most 4 KiB (4096 bytes). `.` never occurs in base64url, so the five parts split unambiguously. The sender's fingerprint is not transmitted: it is the uppercase hex SHA-256 of `cert`.

**Signed text.** The signature is made over the bytes `"LSP1-AUTH-v1"` 0x00 `M` (the domain label of `SigDomain.auth` and a NUL byte, applied by the signing primitive for every signature of the protocol; see the table of domains in section 5), where `M` is UTF-8 text of eight fields separated by LF (0x0A):

```
M = METHOD LF target LF hex(SHA-256(body)) LF ts LF nonce LF serverFp LF clientFp
```

| Field | Value |
|---|---|
| `METHOD` | upper-case HTTP method as sent (`POST`) |
| `target` | the request target exactly as sent: path, and `?` plus the query when there is one, not decoded or normalised (`/api/v1/sessions`); it starts with `/` and has 1 to 2048 printable ASCII characters (0x21-0x7E), anything else is refused |
| `hex(SHA-256(body))` | lowercase hex SHA-256 of the exact request body bytes as sent; for an empty body the digest of the empty string, `e3b0c442...b855` |
| `ts`, `nonce` | the header text of those parts |
| `serverFp` | uppercase hex SHA-256 of the DER certificate the client saw in the TLS handshake of THIS connection |
| `clientFp` | uppercase hex SHA-256 of `cert` |

Known-answer values for a fixed key, request and nonce are in `docs/protocol/test-vectors-inc3.md`.

**Receiver checks.** A failure of checks 1-5 is a 401 AUTH_INVALID with one generic message that does not say which check failed. Binding and MAC failures of check 6 and of the routes (sender mismatch, SAS proof or commitment mismatch, pairing proof) happen after a valid signature, so they are not an oracle for outsiders and MAY carry distinct fixed messages. None of the values is logged.

1. The header is present once, is at most 4 KiB, matches the grammar and has version `v1`.
2. `cert` is at most 2 KiB, parses as strict DER (no indefinite lengths, bounded nesting), is not a CA certificate, and its public key is ECDSA P-256 (other curves are refused). `clientFp` is computed from it.
3. `|now - ts| <= 120 s` (`kAuthWindow`).
4. `M` is rebuilt from what the receiver itself saw: the method and target of the request, the SHA-256 of the body it received, and its OWN certificate fingerprint as `serverFp` (never a value taken from the request). The signature verifies with the key of `cert`; `r` and `s` must lie in `[1, n-1]` of the group order.
5. The pair (`clientFp`, nonce) was not accepted within the last 5 min (cache of 8192 entries per server, the oldest entry goes first). It is remembered only after the signature verified, so unauthenticated floods cannot evict genuine entries; the 240 s the window allows are shorter than the 5 min the cache keeps.
6. The route-specific binding of 4.3.4: for `POST /sessions` and `POST /pair`, `sender.fingerprint` equals `clientFp` and the `CN` of `cert` equals `sender.deviceId`; for `POST /sessions/{sid}/sas`, `clientFp` is the session's sender. `POST /register` carries the registrant's `DeviceInfo`; its fingerprint, when non-empty, MUST equal `clientFp`.

The body must be read before the signature can be checked, so on `POST /sessions` the proof is verified after the body-size step of 4.3.4.

**Clock.** The server sets `Date` on every response, including a 401. A client whose first request is refused with 401 AUTH_INVALID reads `Date`, computes `skew = serverDate - localNow` and retries ONCE with `ts = localNow + skew` and a fresh nonce; a second refusal is final. The server never widens its window.

**Idle body timeout.** In the secure profile a gap of more than 5 s between two bytes of the request body on a JSON route (`/info`, `/register`, `/sessions`, `/pair`, `/sas`) is answered 400 BAD_REQUEST "Request body timed out". The timeout is not applied to `POST .../complete` or to the plaintext profile.

**Routes.**

| Route | `X-LS-Auth` |
|---|---|
| `POST /sessions`, `POST /register`, `POST /pair`, `POST /sessions/{sid}/sas` | required in the secure profile |
| `GET /info` | required on a Contacts-only receiver (5.4), otherwise not needed. A client attaches it only to a peer it has pinned, so its identity is never offered to a server that is not yet authenticated; a stranger's request without it is answered 404 on a Contacts-only receiver |
| `GET /sessions/{sid}`, `POST .../finish`, `POST .../cancel` | not used: TLS channel plus the unguessable `sessionId` |
| `GET .../state`, `PUT .../chunks/{idx}`, `POST .../complete` | not used: `Authorization: Bearer <fileToken>` |

On a Contacts-only receiver the gate of 4.3.4 looks at the certificate of the header before anything else (a header that is absent, malformed or names a non-contact is a stranger, answered 404), and the full verification above follows. For `GET /info` every failure of the full verification is also the plain 404; for the POST routes it is 401 AUTH_INVALID, because the caller already holds a contact certificate (5.4, best effort).

### 4.4 Chunking, acks, resume, cancel

**Chunk math** (`lib/src/transfer/chunker.dart`, `Chunker(chunkSize)`):

- `chunkCount(size) = ceil(size / chunkSize)`; a **0-byte file has 0 chunks**.
- Chunk `i` is the byte range `[i*chunkSize, min((i+1)*chunkSize, size))`; offsets are 64-bit.
- The session's `chunkSize` (default 4 MiB) applies to every chunk computation of that session on both sides.

| File size | chunkCount | Last chunk length |
|---|---|---|
| 0 | 0 | - |
| 1 | 1 | 1 |
| chunkSize - 1 | 1 | chunkSize - 1 |
| chunkSize | 1 | chunkSize |
| chunkSize + 1 | 2 | 1 |
| 5,242,880,000 (spec example) | 1250 | chunkSize |
| 5 GiB = 5,368,709,120 (sparse test) | 1280 | chunkSize |

**Inclusive ranges.** `receivedRanges` is a list of `[first,last]` pairs of chunk indices, **both ends inclusive**: `[[0,41],[50,50]]` means chunks 0 through 41 and chunk 50 (43 chunks). A single chunk is `[n,n]`. The canonical form is sorted, non-overlapping and merged where adjacent (`compactRanges` / `expandRanges` in `session_models.dart`). An empty list means nothing received.

**Per-file flow** [I1]: (optional) `GET /state` -> for each missing chunk `PUT` -> `POST /complete` -> after all files, `POST /finish`. Multiple files go in one session, **smallest first**.

**Receiver storage** [I1]: chunks are written with `RandomAccessFile.setPosition` into `<name>.lspart` next to the final destination. The received-chunk bitmap is kept per file (`ResumeStore`) and persisted to a sidecar `<name>.lspart.json` every 8 newly received chunks, on completion and on flush; it only claims chunks already synced to disk, and a sidecar is accepted only if size, chunkSize, chunkCount, sha256 and modified match the manifest and it is younger than 24 h. Integration with the session store D2 (`sessions/*.json`), resume across channels and the receiver-restart acceptance (FR-15) arrive in [I4]. The final file is produced by `.lspart` -> verify -> rename -> set mtime -> `FileSaved`. A name collision becomes `name (1).ext`.

**Ack and retry.** An ack is HTTP 200. The sender retries a failed chunk up to 3 times (0.5 s, 1 s, 2 s). Retryable errors are those with `retryable:true`; transport errors count as retryable. After a reconnect or channel switch the sender calls `GET /state` and sends **only the missing chunks** - already acked chunks are never re-sent [I4 acceptance].

**Concurrency** (spec): 2 files x 3 chunks on LAN, 4 in flight on tunnel. Memory is bounded by `inFlight x chunkSize`; chunks stream from `file.openRead(start, end)`. Increment 1 uses bounded sequential/parallel sending within these limits; tuning is [I4].

**Timeouts.** Chunk idle timeout 30 s on LAN, 60 s on tunnel [I4]; permission timeout 120 s [I3].

**Cancel.** `POST /cancel` -> the peer's next call gets `410 CANCELLED` -> `FAILED(CANCELLED)`; partials are deleted unless "keep partial files" is enabled.

### 4.5 Tunnel origin API  **[I5]**

The sender runs an HTTP origin bound to `127.0.0.1:<random>`; it is reachable only through the tunnel provider and serves nothing outside `/t/`. Plain HTTP between tunnel and origin is acceptable because the payload is already AES-256-GCM ciphertext.

| Route | Response |
|---|---|
| `GET /t/{token}/manifest` | AES-GCM sealed manifest |
| `GET /t/{token}/f/{fid}/c/{idx}` | `nonce(12) || ciphertext || tag(16)` |
| `POST /t/{token}/ack` | sealed `{fid,idx}` or `{final:true,verified:true}` |
| `GET /t/{token}/healthz` | `204` (DNS-race detection; polled every 2 s up to 45 s) |

- **Link:** `https://<host>/t/<token>#k=<key b64url>&s=<sessionId>&fp=<16 hex>`. The fragment (`k`, `s`, `fp`) never leaves the client and MUST NEVER be logged.
- **Token:** 128-bit random, constant-time compare. Expires at `COMPLETED`, after 30 min idle or 24 h, and is revoked after the final ack; afterwards every route answers 401.
- **Crypto:** AES-256-GCM with a per-session 32-byte key. Nonce = 4-byte `fileIndex` || 8-byte `chunkIndex`; the manifest nonce is `0xFFFFFFFF || 0`. AAD = `sessionId || fileId || idx`.
- **Request shape:** receiver pulls GETs of at most one 4 MiB chunk, at most 4 in flight, no SSE (provider limits: 200 in-flight, 429/1015 -> back off, then switch provider).
- The ordering of the ladder and when the tunnel is used (never while a local tier is healthy, NFR-06) is specified in the build spec section 6.

### 4.6 Versioning and 426

- `v` is `major.minor` (`1.0`). The **path carries the major** (`/api/v1`). Minor versions are additive: unknown fields ignored, new optional members and new `caps` tokens allowed.
- An implementation that does not support the major declared by a peer MUST answer **`426 UPGRADE_REQUIRED`**: the standard envelope plus a **top-level** `supported` array of the majors it speaks, e.g.

```json
{"error":{"code":"UPGRADE_REQUIRED","message":"unsupported protocol major 2","retryable":false},"supported":["1"]}
```

  Trigger: the `v` of the `DeviceInfo` in `POST /register` or in `SessionRequest.sender` has a major other than `1` (`2.0`, `10.1`, `0.9`, empty). A minor difference (`1.7`) is accepted. The check precedes the rest of body parsing. A path under another major (`/api/v2/...`) is unknown to a v1 server and answers 404 (4.3.2). Discovery datagrams with an unknown major are dropped silently (4.2).
  **[I3]** `1.1` is the secure profile (0.3). A peer announcing or reporting any `1.x` is accepted by both profiles; a minor above the receiver's own is never an error.
- Protocol changes MUST update this file, the schemas and the conformance tests in the same pull request. `ApiServer` enforces 426 from [I1]; discovery-side major filtering is [I2].

### 4.7 Compatibility with LSP/1.0 peers  **[I3]**

LSP/1.1 is additive in JSON and routes but not in transport: a secure peer and a plaintext peer cannot talk to each other unless the sender explicitly drops to the plaintext profile. Behaviour of mixed pairs:

| Pair (sender -> receiver) | What happens | On the wire |
|---|---|---|
| secure -> secure | the full protocol: TLS 1.3, pin or SAS, proof, PIN, consent | - |
| secure -> LSP/1.0 or plaintext receiver | refused locally: the receiver's announce or `/info` has an empty fingerprint (a legacy peer), and a secure client never opens a plain-HTTP connection by itself. Listed, not selectable. An explicit insecure override (CLI `--allow-insecure`) uses the plaintext profile, that is the LSP/1.0 wire: no proof, no SAS, no commitment | 0 bytes without the override |
| LSP/1.0 or plaintext -> secure receiver | the TLS-only listener answers the plain-HTTP bytes by closing the connection (closed connection, no HTTP response); the sender sees a connection failure (`NO_CONNECTION`). The receiver logs only an exception type. Client side: a reset or terminated handshake without an OS error is a connection failure (`NO_CONNECTION`); a TLS error with an OS cause (bad version, an HTTP reply to the ClientHello) is an insecure peer | closed connection |
| secure device announces, LSP/1.0 device listens | the datagram is accepted (major 1) and the peer is listed with its fingerprint; the plain `POST http://.../register` the old device sends fails harmlessly; a `bye` is dropped under 4.2 rule 3 and the peer expires after 90 s | - |
| LSP/1.0 device announces, secure device listens | listed as legacy (empty fingerprint); never overrides a pinned device | - |
| new JSON members `sasCommit`, `sas`, `v:"1.1"` | ignored by LSP/1.0 peers (0.2) | - |
| `/sessions/{sid}/sas`, `/pair` | 404 NOT_FOUND on an LSP/1.0 server; the capability tokens `sas` and `pair` (4.2 rule 11) tell a sender in advance | - |
| new error codes `AUTH_INVALID`, `KEY_CHANGED` | an LSP/1.0 client maps an unknown code to `INTERNAL` (retryable): at most 3 harmless retries | - |

## 5. Security summary

| Mechanism | Rule | Marker |
|---|---|---|
| Identity | ECDSA P-256 key generated on first run; self-signed X.509 (CN = deviceId, 10 years); key in OS secure storage (0600 file for CLI/tests). | [I3] |
| Transport | TLS 1.3. The client pins the server's certificate fingerprint in `badCertificateCallback` (wrong certificate refused before any HTTP byte; first contact: SAS). The server does not request a client certificate: the sender proves its identity per request with `X-LS-Auth` (4.3.6), bound to the server fingerprint it saw. Plain HTTP exists only as the plaintext profile (0.3). | [I3] |
| First contact | SAS with commit-then-reveal (5.1): `code = u32_be(SHA-256("LSP1-SAS-V" 0x00 Ns Nr min(fp) max(fp))[0..4]) mod 10^6`, shown as 6 digits on both screens; "Trust this device" pins the fingerprint (TOFU, D1/D3); QR pairing replaces the SAS by a shared secret (5.3). | [I3] |
| PIN (optional) | 6 digits, constant-time compare; 5 failures per IP -> 10 min block; 25 failures from all IPs lock PIN checks (5.2). | [I3] |
| Consent | Non-trusted senders always prompt; trusted auto-accept is opt-in; 120 s timeout -> `FAILED(TIMEOUT)`. Increment 1 offers only `--auto-accept`. | [I3] (auto-accept [I1]) |
| File token | 128-bit, per file, constant-time check, no LAN download API exists. | [I1] |
| Tunnel E2E | AES-256-GCM, key in the URL fragment, provider sees only ciphertext (4.5). | [I5] |
| Rate limits | Per IP: 10 `POST /sessions`/min (`ApiServer`, token bucket), 3 pending prompts (8 in total), 20 discovery packets/s; globally 5 `bye` verifications/s. | [I1] / [I3] / [I2] |
| Input limits | JSON <= 256 KiB (4 MiB for `POST /sessions` in the secure profile [I3]); <= 10,000 files; every size >= 0 and sizes sum to `totalSize`; writes past a file's declared size -> 416. | [I1] |
| Disk exhaustion | Free space >= `totalSize + 64 MiB` before accept; never auto-decompress. | [I3] |
| Corruption | Per-chunk SHA-256 (422 + resend) and whole-file SHA-256 before rename. | [I1] hashing, [I3] acceptance |
| Replay | Random session ids, token binding, state checks. `X-LS-Auth` nonce cache and +-120 s window (4.3.6). | [I1] / [I3] |
| Visibility | Contacts-only: strangers get the 404 of an unknown route; no announce, no mDNS (5.4). | [I3] |
| Redirects | A secure client never follows redirects; neither does the subnet scanner. | [I3] |
| Known limits | The server has no cap on concurrent connections; only per-route body, rate and pending limits apply. | [I3] |
| Logging | Never log file contents, keys, PINs or tunnel URL fragments (`package:logging`, no `print`). | [I1] |

**Filename sanitization** (`lib/src/transfer/filename_sanitizer.dart`; every received `fileName` and `relativePath` is untrusted - cf. CVE-2022-42725). In order: NFC-normalise; split `relativePath` on `/` and `\`, drop empty and `.` segments, **reject** any `..` segment; strip control characters and `<>:"/\|?*`; strip trailing dots and spaces; prefix Windows reserved names (`CON PRN AUX NUL COM1-9 LPT1-9`) with `_`; truncate to 255 UTF-8 bytes keeping the extension; canonicalise (resolving symlinks) and **assert the resulting path is inside the download directory**; collisions become `name (1).ext`. A manifest containing a `..` segment or an unrepresentable name is rejected at `POST /sessions` with 400 BAD_REQUEST. Sanitization and the fuzz suite ship in [I1] (`filename_sanitizer.dart`, `unit/filename_sanitizer_test.dart`, `unit/sanitizer_fuzz_test.dart`); wiring it behind consent, quotas and the TLS-authenticated sender is [I3].

**Signature domains [I3].** Every signature or MAC of the protocol is computed over a domain label, a NUL byte (0x00) and the message, so that a value made for one purpose never verifies for another. The labels are part of the wire format (`SigDomain` in `lib/src/security/contracts.dart`); changing one is a protocol change.

| Label | Used for | Section |
|---|---|---|
| `LSP1-AUTH-v1` | `X-LS-Auth` signature | 4.3.6 |
| `LSP1-SAS-C` | SAS commitment hash | 5.1 |
| `LSP1-SAS-V` | SAS code hash | 5.1 |
| `LSP1-BYE` | `bye` datagram signature | 4.2 rule 9 |
| `LSP1-PAIR-REQ` | pairing request MAC | 5.3 |
| `LSP1-PAIR-ACK` | pairing confirmation MAC | 5.3 |
| `LSP-R1 pair` | `K_pair` HKDF info prefix (shared with Increment 6) | 5.3 |

### 5.1 First contact: SAS commit/reveal  **[I3]**

A short authentication string computed from the two fingerprints alone has 20 bits and no commitment: an attacker who knows the victim's (public) fingerprint can generate 10^6 to 10^7 throw-away certificates until one makes both screens show the same code. LSP/1.1 therefore derives the code from fresh nonces, and the sender commits to its nonce before it learns the receiver's.

Notation: `||` is concatenation; `fpS` and `fpR` are the 64-character uppercase hex fingerprints of the sender and receiver certificates, used as their ASCII bytes; `Ns` and `Nr` are 16 random bytes (CSPRNG); `fpR'` is the receiver fingerprint exactly as the sender saw it in the TLS handshake; `min` and `max` compare the fingerprint strings bytewise.

```
sasCommit = b64url( SHA-256( "LSP1-SAS-C" 0x00 || Ns || fpS || fpR' ) )              ; 32 bytes, 43 characters
code      = u32_be( SHA-256( "LSP1-SAS-V" 0x00 || Ns || Nr || min(fpS,fpR) || max(fpS,fpR) )[0..4] ) mod 10^6
shown     = six digits with leading zeros, grouped 3+3, e.g. "482 913"
```

All fields have a fixed length, so the concatenations are unambiguous. Known-answer values (fixed fingerprints and nonces, hence fixed commitment and code) are in `docs/protocol/test-vectors-inc3.md`.

```
Sender S                                                       Receiver R
  | (TLS: S saw fpR', has no pin for it -> SAS needed)           |
  | choose Ns; sasCommit = H("LSP1-SAS-C" 0x00 || Ns || fpS || fpR')
  |-- POST /sessions {..., sasCommit} + X-LS-Auth -------------->|  4.3.4 checks; R stores the commitment
  |                                                              |  R chooses Nr AFTER the commitment
  |<-- 202 {PENDING, sas:{nonce:Nr}} ----------------------------|  Accept stays disabled
  |-- POST /sessions/{sid}/sas {nonce:Ns} + X-LS-Auth ---------->|  R: H("LSP1-SAS-C" 0x00 || Ns || fpS || fpR) == sasCommit ?
  |                                                              |   no  -> 401 AUTH_INVALID, session FAILED(PROTOCOL_ERROR)
  |<-- 200 {PENDING, sas:{nonce:Nr}} ----------------------------|   yes -> R derives code, shows it with Accept / Reject
  | S derives the same code and shows it                         |
  |            the two users compare the screens                 |
  |-- GET /sessions/{sid}?wait=25 -------------------------------|  held until Accept, Reject or timeout
  |<-- 200 {IN_PROGRESS, acceptedFiles} | FAILED(REJECTED) -------|
```

Rules:

- The sender includes `sasCommit` iff it cannot authenticate the receiver, that is it has no pin for `fpR'`. A sender with a pin sends none, and the receiver may then auto-accept a trusted contact (if the user enabled that).
- If the answer to a request that carried `sasCommit` is not a `PENDING` status with `sas.nonce` (a receiver that ignores the member, an LSP/1.0 receiver, or an immediate `IN_PROGRESS`), the sender MUST cancel the session and send nothing further (`FAILED(PROTOCOL_ERROR)`): without the reveal the receiver is not authenticated.
- A receiver that gets a `sasCommit` never auto-accepts, whatever the trust level, so the first-contact human comparison always happens. The receiver cannot enable Accept before the code exists; otherwise a sender that never reveals would bypass the SAS.
- A relaying man-in-the-middle terminates TLS with its own certificate, so `fpR'` differs from the receiver's own fingerprint and the reveal check fails without any human comparison. A man-in-the-middle that uses its own identity towards both ends produces a different code on each screen (the nonces and the fingerprints differ), which the users see.
- `Nr` (`sas.nonce`) is chosen after the commitment, is returned in every `SessionStatus` while the session is `PENDING`, and does not change.
- Deadlines: the reveal must arrive within 30 s of the 202 (`kSasRevealTimeout`), otherwise `FAILED(TIMEOUT)`; the consent deadline of 120 s (`kPermissionTimeout`) runs from session creation as before and covers the reveal too.
- A commitment that does not match the revealed nonce is 401 AUTH_INVALID and `FAILED(PROTOCOL_ERROR)`. A pin mismatch (KEY_CHANGED) is never overridden by a SAS.
- The sender does not gate on its own SAS: both screens show the code, but the RECEIVER's Accept is the human comparison. Data flows only after that Accept; the sender's user may cancel at any time.
- When the receiver's user accepts a SAS session the sender's fingerprint is pinned automatically as `known`; the sender pins the receiver when its transfer becomes `IN_PROGRESS`. `trusted` (auto-accept) is a separate opt-in; `/pair` stores `trusted` (5.3).
- At Accept the receiver rechecks the sender: if it was blocked or re-keyed while the prompt was open, the session becomes `FAILED(REJECTED)` and Accept fails with BLOCKED or KEY_CHANGED.
- Limits, stated honestly: with the commitment each attempt succeeds with probability 10^-6 and costs one visible prompt, throttled by 10 requests/min and 3 pending prompts per IP. A user who compares the code with the wrong person (a relay attack on the human) is not preventable by the protocol; the consent screen shows alias, platform and address for that reason.

### 5.2 PIN and throttling  **[I3]**

- A PIN is 6 decimal digits drawn uniformly (rejection sampling) and compared in constant time. It is never logged, echoed or put in an error message. The receiver's policy is off (default), fixed, or a new PIN per Receive window, optionally one-time (consumed atomically when the session is registered); trusted contacts are exempt by default.
- The sender sends `pin` only after `401 PIN_REQUIRED`, never unprompted. A `pin` that is present but not exactly six ASCII digits is a shape error: 400 BAD_REQUEST, never a strike; an absent `pin` is PIN_REQUIRED. A wrong, expired or already used PIN is answered identically (`401 PIN_INVALID`, same body, same status) and counts as a strike, so the answer is no oracle.
- 5 failures from one source IP inside 10 min -> `403 BLOCKED` for 10 min, even for the correct PIN, with `Retry-After`. 25 failures from all IPs inside 10 min -> PIN checks are locked for 10 min (a request that needs a PIN gets `403 BLOCKED`) and the PIN is rotated. The block is consulted in the PIN step of 4.3.4 (step 10), not before the body is read. Blocks live in memory; a restart clears them.
- The PIN is an anti-spam authorization, not authentication: a man-in-the-middle at first contact can read it, because it travels inside TLS to a server that is not yet authenticated.

### 5.3 Pairing  **[I3]**

Pairing replaces the SAS comparison by a secret that the two devices share through the QR code. Invite URI (4.2 rule 6):

```
libreshare://pair?v=1&s=<S, 43 chars b64url>&id=<deviceId>&fp=<64 hex>&n=<alias>&ip=<ip>&port=<port>
```

`s` is the invite secret `S` (32 random bytes) and is reserved for pairing; the member `r=` (relay hints) is added by Increment 6 and is not defined here. Unknown members are ignored. Flow (A is the inviter that shows the QR, B the scanner):

1. A creates `S`: 32 random bytes, valid 10 min, single use, kept in memory only. It shows the URI as QR code or text.
2. B opens TLS to `ip:port` with the `fp` of the QR pinned (a different certificate aborts the connection), chooses `nB` (16 random bytes) and sends `POST /pair` (4.3.4) with `mac = HMAC-SHA256(S, "LSP1-PAIR-REQ" 0x00 || fpB || fpA || nB)` and its `X-LS-Auth` proof.
3. A verifies, shows alias and platform of B with Accept / Decline (no SAS: `S` authenticates B) and holds the request for at most 125 s (`kPairTimeout`).
4. On Accept A answers `PairResponse{accepted:true, responder, nonce: nA, mac}` with `mac = HMAC-SHA256(S, "LSP1-PAIR-ACK" 0x00 || fpA || fpB || nA || nB)`; B verifies it. On Decline or timeout A answers `accepted:false` without `nonce` and `mac`.
5. Both sides pin each other as trusted contacts (fingerprint, deviceId, alias) and derive `K_pair = HKDF-SHA256(ikm=S, salt=nA || nB, info="LSP-R1 pair" || min(fpA,fpB) || max(fpA,fpB), L=32)`, with the fingerprints as ASCII hex as in 5.1. `K_pair` never travels, is stored in the secret store as `kpair/<deviceId>` (absent for contacts made by SAS), and `S` is erased. Increment 6 reuses `K_pair`; the label `LSP-R1 pair` is shared with its rendezvous design.

### 5.4 Contacts-only visibility  **[I3]**

A receiver whose visibility is Contacts-only keeps its listener bound but is invisible to strangers (design 01 section 1.3).

- Discovery: no periodic multicast, no mDNS registration; a probe is answered only for a contact's fingerprint (4.2 rule 10).
- A **contact** is a trust-store entry that is neither unknown nor blocked (`known` after a SAS-confirmed first contact, or `trusted`). A **stranger** is any request without a well-formed `X-LS-Auth`, or whose certificate fingerprint is not a contact.
- On `GET /info`, `POST /register` and `POST /sessions` a stranger gets `404 NOT_FOUND`, byte for byte the envelope an unknown route gets: no new error code, no distinguishing header, no oracle. This holds even when the proof is otherwise valid; once a contact is removed it is 404 again.
- A contact is served after the full verification of 4.3.6. For `GET /info` a failed verification is also the plain 404; for the POST routes it is 401 AUTH_INVALID.
- Exempt: `POST /pair` (answered per 4.3.4, the invite secret authenticates), and the session and file routes of an already accepted session (session id and file token).
- Best effort: the fingerprint claim in a UDP probe is not authenticated, so anyone who knows a contact's fingerprint can learn that the device exists. HTTPS stays closed to strangers.

Threat-to-test mapping is in `docs/traceability.md` and spec section 5.

## 6. Session state machine

```
PENDING --accept--------------------> IN_PROGRESS --all files verified + finish--> COMPLETED
PENDING --reject / timeout(120 s)---> FAILED(REJECTED | TIMEOUT)
PENDING --sas reveal missing (30 s)-> FAILED(TIMEOUT)                 [I3]
PENDING --sas reveal != commitment--> FAILED(PROTOCOL_ERROR)          [I3]
IN_PROGRESS --verify fails----------> FAILED(VERIFY_FAILED)
IN_PROGRESS --cancel----------------> FAILED(CANCELLED)
IN_PROGRESS --no connection left----> FAILED(NO_CONNECTION)        [I4]
IN_PROGRESS --out of space----------> FAILED(DISK_FULL)
IN_PROGRESS --malformed peer--------> FAILED(PROTOCOL_ERROR)
IN_PROGRESS --channel failure, next channel available--> IN_PROGRESS (fallbackToNext)  [I4]
```

In the secure profile a session created with a `sasCommit` leaves `PENDING` only after the reveal arrived AND a human accepted (5.1). `COMPLETED` and `FAILED` are terminal. Session state is kept 24 h after `NO_CONNECTION` [I4].

## 7. Conformance

The authoritative status of each test is in `docs/traceability.md`. Test files live under `packages/libreshare_core/test/`. Conformance tests MUST NOT be edited to make a failing implementation pass; a failing conformance test means the code or this document is wrong and the change goes through the protocol-change rule.

| Part of the protocol | Verified by | Marker |
|---|---|---|
| REST contract over real HTTP, tested with a raw `dart:io` client: every route, status, `Authorization`, `X-LS-Chunk-SHA256` (case-insensitive), ack idempotency, 400/401/404/409/410/413/416/422/429/500, error envelope for every `LsErrorCode` on every route, `wait` clamping, body limits, unknown-field tolerance, 426 with `supported`, rate limit | `test/conformance/api_conformance_test.dart` (ApiServer against `test/helpers/api_fake_handler.dart`) | [I1] |
| Client side of the same contract (ApiClient round-trips against ApiServer, error envelope -> `LsException`, streaming body, `Content-Length`) | `test/unit/api_client_test.dart` | [I1] |
| JSON shapes: every DTO's `toJson()` output and every schema `examples` entry validates against `docs/protocol/schemas/*.schema.json`; golden fixtures round-trip; unknown members ignored; `LsErrorCode` table equals section 4.3.5 | `test/conformance/schema_conformance_test.dart` | [I1] |
| Chunk math: sizes 0, 1, chunkSize-1, chunkSize, chunkSize+1, 5 GiB sparse; inclusive ranges | `test/unit/chunker_test.dart` | [I1] |
| Manifest: multi-file, smallest first, chunkCount/size consistency, null `sha256` over 2 GiB | `test/unit/manifest_test.dart` | [I1] |
| Hashing: streaming and isolate SHA-256, per-chunk hash | `test/unit/hashing_test.dart` | [I1] |
| Sender behaviour against a fake `PeerClient`: retries, long-poll, skipping unaccepted files, 0-byte files, events | `test/unit/file_sender_test.dart` | [I1] |
| Receive path: `.lspart`, idempotent chunk, reassembly, atomic rename, `FileSaved`, bitmap, chunk and file hash failure | `test/unit/file_receiver_test.dart`, `test/unit/resume_store_test.dart` | [I1] (full corruption acceptance [I3]) |
| Filename sanitizer incl. fuzz | `test/unit/filename_sanitizer_test.dart`, `test/unit/sanitizer_fuzz_test.dart` | [I1] |
| Request-rate limiter | `test/unit/rate_limiter_test.dart` | [I1] |
| End-to-end transfer between two engines in one process: multi-file, 0-byte file, completion events on both sides, A->B then B->A (also concurrently), reject / timeout, path traversal, receiver shutdown race; 64 MiB and (with `LS_SLOW=1`) 5 GiB sparse | `test/integration/two_engine_test.dart`, `test/integration/large_transfer_test.dart` | [I1] |
| Two real CLI processes over loopback; argument errors (exit 64 / 66) | `packages/libreshare_cli/test/cli_loopback_test.dart` | [I1] |
| CLI loopback of a 100 MiB random file + `cmp` | `tools/loopback_smoke.sh` (CI smoke step in `.github/workflows/ci.yml`) | [I1] |
| Discovery datagram: parse, drop rules, size, rate limit; two-container discovery <= 3 s | `test/unit/discovery_packet_test.dart`, Docker e2e | [I2] |
| TLS handshake, pinning, SAS vectors, PIN, consent, oversize | `mtls_handshake_test` (name kept from the seed), `mitm_test`, `sas_test`, `rate_limit_test`, `oversize_test`, `permission_test` | [I3] |
| LSP/1.1 JSON and document: the four new schemas (examples, length/member/type negative controls), DTO round trips of `sasCommit`, `sas`, `PairRequest`, `PairResponse`, golden fixtures, the route table, error table, check order, constants, signature domains and every [I3] section of this file, the plaintext profile staying the LSP/1.0 wire | `test/conformance/lsp11_conformance_test.dart` with fixtures in `test/conformance/fixtures/lsp11/` | [I3] |
| Known-answer vectors: SAS commitment and code, `X-LS-Auth` header and signed text, HKDF `K_pair`, pairing MACs | `docs/protocol/test-vectors-inc3.md`, consumed by `test/unit/{sas,identity_proof,crypto_primitives,pairing}_test.dart` and `lsp11_conformance_test.dart` | [I3] |
| Resume across channels / receiver restart, fallback | `resume_after_crash_test`, `fallback_test`, `ladder_order_test`, `cut_wifi` Docker e2e | [I4] |
| Tunnel origin, ciphertext-only capture, token expiry | `e2e_ciphertext_test`, `token_test`, fake-tunnel Docker e2e | [I5] |

## 8. Increment matrix

| Section | I1 | I2 | I3 | I4 | I5 |
|---|---|---|---|---|---|
| 4.1 defaults | constants, server port fallback | announcing the port, multicast | TLS 1.3, version 1.1, 4 MiB `POST /sessions`, auth constants | - | - |
| 4.2 discovery | - | full | `bye`, pair URI, Contacts-only replies, caps `sas`/`pair` | - | - |
| 4.3 REST | full over HTTP, no TLS; 426; per-IP rate limit | `/register` callers | TLS 1.3, `X-LS-Auth` (4.3.6), `/sas`, `/pair`, PIN, BLOCKED, KEY_CHANGED, consent, 507, Contacts-only 404 | channel switching | `tunnelOffer` populated |
| 4.4 chunks / resume | chunking, ack, `.lspart` + sidecar bitmap | - | corruption acceptance, chunk hash mandatory in the secure profile | D2 integration, `/state` resync across channels, restart acceptance | - |
| 4.5 tunnel origin | - | - | - | - | full |
| 4.6 versioning | 426 enforced by ApiServer | discovery-side filtering | `1.1` secure profile, accepted by both profiles (0.3, 4.7) | - | - |
| 5 security | token, input limits, sanitizer, rate limit | discovery rate limit | full (5.1-5.4) | - | tunnel E2E |
