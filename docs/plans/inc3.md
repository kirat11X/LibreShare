# Increment 3 - Security, permission, verification (Sprint 3)

Status: PLAN, nothing started. Gate: Inc 3 must not start until Inc 2 acceptance passes (Inc 2 Phase 2, app + Docker timings, is still being finished by another agent). Date: 2026-11-04. Author: planning agent (no code, no tests, no builds were run for this document).
Sources: spec §5, §12 Increment 3; `docs/roadmap.md` (Inc 3 row, "Defaults adopted", "Spec amendments"); `docs/design/01` §1.3/§4/§6; `docs/design/02` §3.2/§7.1; `docs/design/03` §3.7; `docs/design/04` (reuse of `cert_factory`); `docs/plans/inc1.md`, `inc2.md`; `docs/protocol/LSP-1.md` + schemas; code under `packages/libreshare_core/lib/src` and `apps/libreshare_app/lib` as of today.
Evidence tags: `[Sn]` = source list at the end. **UNVERIFIED** = not confirmed by a source I could read or by a run; every UNVERIFIED item has a spike or a test that settles it (section 2 spikes, section 8 risks). Cost rule: everything below is $0 for users and maintainers.

## 0. Findings that change the plan (read first)

1. **`dart:io` cannot do first-contact mutual TLS with self-signed client certificates.** `HttpServer.bindSecure` has `requestClientCertificate` but no `requireClientCertificate` and no bad-certificate hook; `SecureServerSocket.bind` has both flags but still no `onBadCertificate`; `_RawSecureSocket` registers a bad-certificate callback only when one is passed, and the server path passes none [S1]. The native code sets `SSL_set_verify(PEER)` with no custom callback on the server [S2]. The SDK's own client-certificate test makes the server trust the client authority (`setTrustedCertificates` + `setClientAuthorities`) [S3]. Conclusion (UNVERIFIED until spike S-A, 30 min): a stranger's self-signed client certificate fails the handshake, so TOFU/SAS first contact is impossible with TLS client certificates. The spec's "server `requestClientCertificate: true`" (§5, LSP-1 §5) cannot be implemented as written. **Plan: TLS server authentication (pinned) + a signed client proof (D1).** This is a spec amendment (FR-05 wording "mutual TLS" becomes "mutual authentication over TLS 1.3") and the one decision most worth a veto.
2. **The spec's SAS is grindable.** `SAS = SHA-256("LSP1-SAS" || min(fp) || max(fp)) mod 10^6` has 20 bits and no commitment. An attacker who knows the victim's (public) fingerprint can pre-compute about 10^6 to 10^7 throw-away certificates (minutes of CPU) and pick one whose SAS equals the code on the other side. Needs commit-then-reveal with fresh nonces (D4). Amendment of spec §5 / LSP-1 §5.
3. **`cryptography` 2.9.0 has no pure-Dart NIST P-256** [S4]; `pointycastle` 4.0.0 (MIT, deps `collection`, `convert`) provides ECDSA [S5]. The only new core dependency is `pointycastle`. `basic_utils` 5.8.2 can sign EC certificates but only through a CSR round-trip and drags in `http`, `archive`, `json_annotation`, `logging` [S6]; rejected (D2).
4. **Every client in the repo is plain HTTP today**: `engine.peerInfo`/`sendFiles` (`engine/libreshare_engine.dart:463,480`), `defaultInfoProbe` (`discovery/subnet_scanner.dart:48`), `ApiPeerRegistrar` (`discovery/peer_registrar.dart:53`), the manual-peer resolver, app `services/outgoing_run.dart:66`. 15 test files build engines/servers/clients with plaintext defaults. TLS therefore lands as an explicit `SecurityConfig` mode; library defaults stay plaintext (the documented Inc 1 loopback profile), the app is always secure, and the **CLI default flip needs the user's approval** (question Q2, section 11).
5. **Design 03 already names "LSP 1.1"** for its two Inc 7 fields. Inc 3 takes `1.1`; Inc 7's additions become `1.2` (one-line edit to `docs/design/03` §3.7 and the roadmap note when Inc 7 starts).
6. The CLI invents a random `deviceId` per run (`_selfFrom` in `ls_cli.dart`), so TOFU is meaningless there. Inc 3 gives the CLI a persistent identity directory.

## 1. Scope

In scope (spec §12 Inc 3 tasks plus the roadmap Inc 3 row):

- Identity: `CertFactory` (pure Dart ECDSA P-256 self-signed cert), D3 `CredentialStore`, `SecretStore` implementations, TLS listener (`bindSecure`) and pinned TLS client.
- Mutual authentication: signed client proof (`X-LS-Auth`), channel binding to the server fingerprint, replay cache.
- First contact: SAS with commit/reveal, TOFU trust store (D1), key-change refusal on both sides, block list.
- PIN (optional), per-IP and global throttling, pending-prompt caps, existing 10/min request limit kept.
- Consent: Accept/Reject UI with SAS, 120 s timeout, notification with actions, auto-accept for trusted contacts (opt-in, per contact).
- Contacts-only visibility (design 01 §1.3), QR pairing that reserves `s=` and a nullable `K_pair` (design 02 §3.2/§7.1), goodbye datagram.
- Per-chunk hash header mandatory in secure mode, corrupted-chunk and corrupted-file acceptance end to end, sanitizer through TLS (already built in Inc 1, re-proved end to end).
- Android `ReceiveService` (type `connectedDevice`) as a SPIKE package; manifest delta of design 01 §4.5; `usesCleartextTraffic` removed.
- LSP/1.1 (LSP-1.md + schemas + conformance together), Docker e2e additions, traceability.

Explicit non-goals (each belongs to a later increment, do not start them here): tunnel, `TunnelProvider`, `tunnel_crypto`, AES-GCM (Inc 5; the identity-signing primitive written here is reused by Inc 5/5b/6/7); `ConnectionManager`, candidates, D2 session store, resume across channels, AOT/native hashing, NFR-02 (Inc 4); rendezvous, Nostr/ntfy, relay lists, presence (Inc 6; Inc 3 only stores `s` and a nullable `K_pair`); BLE/hotspot (Inc 7; Inc 3 only preserves unknown D1 fields such as `peerAdvKey`); signed discovery announcements; automatic or cross-signed key rotation; TLS client certificates; "my devices" group secret; folders (NFR-08); Windows/Linux packaging, SignPath, firewall installer rules (Sprint P); Google Play; any paid service.

## 2. Cryptographic and security decisions (settle before coding)

### D1 Authentication model (the big one)

- **Recommend:** TLS 1.3, server certificate = the device identity certificate; the receiver does NOT request client certificates. The sender proves its identity per request with an ECDSA P-256 signature (`X-LS-Auth`, section 3 item 3) that covers method, path, body hash, timestamp, nonce, **the server fingerprint the client saw in the TLS handshake** and the client fingerprint. The sender pins the receiver in `badCertificateCallback` (client `SecurityContext(withTrustedRoots: false)`); the receiver authenticates senders from the proof and its trust store. Session-level secrecy stays as in LSP-1 §4.3.1 (random session id and file tokens inside TLS).
- Why it holds: a relaying MITM terminates TLS with its own certificate, so the proof the sender signs names the MITM's fingerprint, and the real receiver (whose own fingerprint differs) rejects the replayed proof; an impersonating MITM (own identity to both ends) is caught by the SAS (D4) or by the pin.
- Reuse: the same sign/verify helper with a domain-separation label serves Inc 5 (link manifests, design 04 F9), Inc 6 (presence records, design 02 §3.4) and Inc 7 (BLE AUTH, design 03 §3.7), none of which can use TLS client certificates (the tunnel provider terminates TLS).
- **Rejected:** (a) true mTLS with pre-trusted client certificates: works only for already-paired peers, first contact still fails, and updating the server's trust set per pairing at runtime is UNVERIFIED; (b) a second plaintext "introduction" port: reopens the downgrade surface; (c) a pure-Dart TLS stack or FFI to OpenSSL: unaudited / three native builds; (d) protocol sniffing on one port (TLS vs HTTP): `HttpServer.listenOn` takes a `ServerSocket`, `SecureServerSocket` is not one [S1], so it needs a hand-built socket multiplexer for no gain.
- **Spike S-A (first task of P1, scratch dir, result in `docs/test-reports/inc3-spikes.md`):** confirm that an untrusted self-signed client certificate fails the server handshake on Dart 3.13.7 (Linux). If it unexpectedly succeeds, D1 is unchanged (the proof is still the authenticator; `request.certificate` is then an optional extra check), so no replan.

### D2 Certificate generation in pure Dart

- **Recommend:** own `security/cert_factory.dart` (about 250 lines): `pointycastle` 4.0.0 for P-256 key generation (`FortunaRandom` seeded from `Random.secure()`), deterministic ECDSA (RFC 6979 style, no RNG needed when signing; confirm the API in P1 tests) and its ASN.1 classes to build `TBSCertificate`, plus a 40-line strict DER reader (length caps, no indefinite lengths) used to pull SPKI out of a peer certificate. Profile: X.509 v3, serial = 127 random bits, signature `ecdsa-with-SHA256`, `CN=<deviceId>` (issuer = subject), `notBefore` = now - 24 h, `notAfter` = +3650 d, BasicConstraints CA:false (critical), KeyUsage digitalSignature (critical), ExtendedKeyUsage serverAuth, **no SAN** (peers connect by IP; pinning replaces name checks). Key stored as PKCS#8 PEM, certificate as PEM + DER.
- **Rejected:** `basic_utils` (CSR round-trip; its digest selection may ignore the CSR algorithm; heavy transitive deps; claim from a tool summary, not run: UNVERIFIED) [S6]; shelling out to `openssl` (absent on Windows/Android); `cryptography` (no pure-Dart P-256) [S4]; FFI to BoringSSL (native build burden); RSA (slow keygen in Dart).
- **UNVERIFIED, settled by P1 tests/spike S-B:** `SecurityContext.usePrivateKeyBytes` accepts a PKCS#8 EC PEM (docs say "PEM or PKCS12" [local SDK `security_context.dart`]); Dart's client calls `badCertificateCallback` for the missing-SAN/IP mismatch and `X509Certificate.der` is populated (the field exists [local SDK]; the native client sets host/IP verification parameters [S2]); pointycastle P-256 speed in AOT and on a mid Android phone (budget: keygen <= 500 ms, sign <= 50 ms, verify <= 100 ms; if exceeded, cache verified proofs per session and sign once per session, not per request); `openssl x509 -text` and `openssl verify -no-CAfile` as external oracles in a test that skips when `openssl` is absent.

### D3 What is pinned: fingerprint and certificate lifetime

- **Recommend:** keep the spec definition: fingerprint = uppercase hex SHA-256 of the **DER certificate**. The certificate is generated once with the key, stored with it, and never re-issued for the same key (10-year validity; pins ignore expiry; Settings warns below 1 year left). Hashing needs no parsing of attacker-controlled bytes before authentication, and the value already flows through announce, mDNS `fp`, `libreshare://peer` links and `PeerRegistry`.
- **Rejected:** SPKI-hash fingerprint (survives certificate re-issue, but changes the LSP-1 §0.2 definition, still needs a DER walk on the TLS side, and gains nothing while certificates are immutable); pinning the raw public key only at app layer (no TLS-level refusal).
- Identity loss: key unreadable or certificate missing while D1 has peers => `IdentityLost` state surfaced in UI/CLI; a new identity is created only after an explicit "Create new identity" action. Never silently regenerate (peers would see KEY_CHANGED).

### D4 SAS: commit-then-reveal, 6 digits

- **Recommend:** sender picks `Ns` (16 random bytes) and sends `sasCommit = SHA-256("LSP1-SAS-C\0" || Ns || fpS || fpR')` in `POST /sessions` (`fpR'` = fingerprint of the server certificate **as the sender saw it**). The receiver replies with `sas.nonce = Nr` (16 random bytes, chosen after the commit). The sender then reveals `Ns` (`POST /sessions/{sid}/sas`); the receiver recomputes the commit with its own fingerprint (a relaying MITM fails here without any human comparison) and only then derives the code. `code = u32_be(SHA-256("LSP1-SAS-V\0" || Ns || Nr || min(fpS,fpR) || max(fpS,fpR))[0..4]) mod 10^6`, shown as `482 913` on both screens; the receiver cannot press Accept before the code exists (otherwise a sender that never reveals would bypass SAS). Reveal deadline 30 s (`FAILED(TIMEOUT)`), consent deadline 120 s as before.
- Sender includes `sasCommit` iff it cannot authenticate the receiver (no pin). A receiver that gets a commit never auto-accepts (so the first-contact human check always happens); a sender with a pin sends none and the receiver may auto-accept a trusted contact.
- Why 6 digits: with the commitment each attempt succeeds with probability 10^-6 and costs one visible prompt, throttled by 10 requests/min, 3 pending prompts per IP; same as Bluetooth numeric comparison. Rejected: no-nonce hash (grindable, finding 2); word lists or emoji (font, i18n and accessibility cost; 2 words of a 256-word list is only 16 bits); 8 digits (UX cost for a threat the commitment already bounds); ZRTP-style full DH (we already have signed keys).
- Test vectors (fixed fingerprints and nonces => fixed commit and code) are published in LSP-1 and shared with Inc 5 link-SAS work.

### D5 PIN: format, throttling, expiry

- **Recommend:** 6 digits from `Random.secure()` with rejection sampling, compared with `constantTimeEquals`; modes `off` (default), `fixed` (user-set, persisted in `SecretStore`), `window` (new PIN each Receive window, optional TTL); flag `oneTime` consumes a PIN after one authorised session. Trusted contacts are exempt (`pinExemptContacts`, default on). The sender asks for the PIN only after `401 PIN_REQUIRED` (a PIN is never sent unprompted). Expired or consumed PIN is answered exactly like a wrong PIN (`PIN_INVALID`, counts as a strike; no oracle).
- Throttle: 5 failures per source IP inside 10 min => `403 BLOCKED` for 10 min (even for the correct PIN); **global** 25 failures from all IPs inside 10 min => PIN checks locked for 10 min, PIN rotated, event `PinBruteForceSuspected` (an attacker with many IPv6 addresses defeats per-IP only). `Retry-After` set. Blocks live in memory (a restart clears them; documented).
- Limits stated honestly: the PIN is an anti-spam authorization, not authentication; a MITM at first contact can read it (it travels inside TLS to an unauthenticated server). Rejected: HMAC PIN proof (a 20-bit secret is brute-forced offline from the proof), SRP/PAKE (no maintained pure-Dart package found: UNVERIFIED, out of scope).

### D6 Key storage per platform (all free)

| Platform | Private key + `K_pair` + PIN | Why / risk |
|---|---|---|
| CLI, Docker, tests, Linux app | `FileSecretStore`: file with mode 0600 in `$LS_HOME` or the app-support dir, atomic tmp+rename | `flutter_secure_storage` on Linux needs libsecret and a running, unlocked keyring and gives no behaviour for "no keyring" [S7]; autostart at login can run before the keyring unlocks. A same-user attacker reads either store anyway. |
| Windows app | `FileSecretStore` in `%APPDATA%` (user-profile ACL) in Inc 3; `flutter_secure_storage` 11.2.0 optional behind `SecretStore` once its Windows mechanism is read (the page does not name it) [S7]: UNVERIFIED | needs ATL in the build tools |
| Android app | `flutter_secure_storage` 11.2.0 (Keystore-wrapped AES-GCM, minSdk 23, `allowBackup=false` already set in the manifest) [S7] | CI-built only |

`SecretStore` is an interface in core (async get/put/delete of bytes by name); platform implementations live in `apps/libreshare_app/lib/platform/secret/`. The certificate and D1/D3 metadata are not secret and live in plain atomic JSON. Never log keys, PINs, `S`, `K_pair`, nonces, full fingerprints (16-hex prefix max).

### D7 Key rotation

- **Recommend:** none automatic. "Reset identity" (CLI `ls identity rotate`, Settings) creates a new key and certificate; peers then see KEY_CHANGED (D1 record keeps the old pin until the user removes or re-confirms). Cross-signed rotation is rejected for Inc 3: it only helps planned migration (10-year certificates make that distant), and the case rotation exists for (stolen key) is exactly where an old-key signature proves nothing. `kProtocolVersion`-gated reservation: none needed.

### D8 TLS parameters

TLS >= 1.3 via `SecurityContext.minimumTlsProtocolVersion` (exists in Dart 3.13.7 [local SDK]; enforcement on Android/Windows UNVERIFIED, test with `openssl s_client -tls1_2` when present); no ALPN; HTTP/1.1; `withTrustedRoots: false` on both sides so every peer certificate goes through the pin callback; no session tickets configuration; the client never follows redirects (already true).

### D9 Proof, replay, clock

Nonce 16 bytes, timestamp in ms, accepted window +-120 s, nonce cache 5 min / 8192 entries (LRU) per server, certificate size cap 2 KiB, header cap 4 KiB. A client learns skew from the `Date` response header of its first call and retries once with the corrected timestamp (UNVERIFIED that dart:io always sets `Date`; test in P3). Signature = raw `r||s` (64 B), verify rejects `r,s` outside the group order and non-P-256 keys.

### D10 Plaintext profile and downgrade

TLS is never negotiated down. `ApiClient(https: true)` never falls back; a peer with an empty fingerprint is "legacy": listed disabled in the app (CLI shows `legacy=1`), sending needs the CLI flag `--allow-insecure`; an announce with an empty or different fingerprint never overrides a pinned device (the `PeerRegistry` baseline rule exists and is extended to D1). A TLS-only listener answers a plaintext client with a closed connection (no HTTP body, nothing logged beyond the exception type).

### D11 JSON cap vs 10,000 files (carried from Inc 1)

**Recommend:** add `kMaxSessionJsonBytes = 4 MiB` for `POST /sessions` only (10,000 files x about 260 B = 2.6 MB), all other bodies stay at `kMaxJsonBytes = 256 KiB`; `Content-Length` required above 256 KiB; at most 2 concurrent oversize bodies per server; rate limit still runs first. Rejected: lowering the file limit to 1,000 (blocks future folder sends), manifest pagination (new endpoint and an incomplete-manifest state), gzip request bodies (decompression-bomb surface). Body hashing for the proof costs about 60 ms at 70 MB/s for 4 MiB, acceptable.

### D12 Goodbye datagram (carried from Inc 2)

**Recommend:** signed `bye` datagram `{"proto":"libreshare","v":"1.1","t":"bye","deviceId","fingerprint","ts","sig"}` (about 400 B), sent twice (50 ms apart) when the listener closes or Receive goes Off; receivers verify (ECDSA over `"LSP1-BYE\0" || deviceId || fp || ts`, window +-60 s, at most 5 verifications/s globally) and call a new `PeerRegistry.remove`. Different shape (no `announce`) so LSP/1.0 decoders drop it silently and the peer expires after 90 s as before. Rejected: unsigned bye (any LAN host could blank the device list).

### D13 Pairing (reserve, LAN only)

`libreshare://pair?v=1&s=<32 B b64url>&id=&fp=<64 hex>&n=&ip=&port=` (`r=` relay hints are added by Inc 6). Inviter holds `S` for 10 min, single use. Scanner connects with the QR fingerprint pinned, sends `POST /pair` with `mac = HMAC-SHA256(S, "LSP1-PAIR-REQ\0" || fpB || fpA || nB)` and its proof; inviter shows alias + Accept (no SAS: `S` authenticates), pins both ways as `trusted`, and both derive `K_pair = HKDF-SHA256(ikm=S, salt=nA||nB, info="LSP-R1 pair"||min(fp)||max(fp), L=32)` exactly as design 02 §3.2 so Inc 6 inherits stored keys; `S` is erased. `K_pair` is nullable (SAS/TOFU contacts have none) and stored in `SecretStore` as `kpair/<deviceId>`; D1 keeps only a reference. Cut candidate if the sprint slips (section 8, R5): keep the QR format and `s=` generation, drop `POST /pair` and pin via SAS.

## 3. Protocol changes: LSP/1.0 -> LSP/1.1 (additive; docs + schemas + conformance move together)

`kProtocolVersion = '1.1'` (`kSupportedMajors` stays `['1']`). Marker `[I3]` in LSP-1.md. New conformance file `test/conformance/lsp11_conformance_test.dart` (new file; the Inc 1 conformance files are not edited, they must stay green).

| # | Change | LSP-1 section / schema | Compatibility with 1.0 peers |
|---|---|---|---|
| 1 | **Transport profile [I3]:** HTTPS only, TLS >= 1.3, identity certificate profile of D2, server never requests client certs, client pins. Plain HTTP stays defined as the loopback/test profile ("plaintext profile"), selected only by `SecurityConfig.plaintext` / CLI `--insecure-plaintext` | §0.1, §4.1, §5 | **Not wire compatible with 1.0 plain-HTTP peers, by design.** 1.0 already specified TLS as [I3] and called plain HTTP loopback-only. Mixed pair: new sender -> 1.0 receiver is refused locally (empty fingerprint) with 0 bytes sent; 1.0 sender -> new receiver gets a closed connection (`NO_CONNECTION`). |
| 2 | `DeviceInfo.fingerprint` non-empty in secure mode; definition unchanged | `device-info`, `discovery-announce` schemas (text only) | 1.0 decoders already accept 64-hex. |
| 3 | **`X-LS-Auth` request header:** `v1.<cert b64url>.<ts ms>.<nonce b64url>.<sig b64url>`; signed text `"LSP1-AUTH-v1\n"+METHOD+"\n"+path+query+"\n"+hex(SHA-256(body))+"\n"+ts+"\n"+nonce+"\n"+serverFp+"\n"+clientFp`. Required on `POST /sessions`, `POST /register`, `POST /pair`, `POST /sessions/{sid}/sas`; on `GET /info` only for Contacts-only receivers. File-token routes unchanged. | new §4.3.6 + `x-ls-auth` grammar in a new `auth-proof.schema.json` (decoded form) | Header ignored by 1.0 servers. |
| 4 | `SessionRequest.sasCommit` (optional, 43 chars b64url) and `SessionStatus.sas` (optional `{nonce}`, 22 chars b64url) | `session-request`, `session-status` schemas | Unknown members ignored. |
| 5 | **`POST /sessions/{sid}/sas`** body `{nonce}` -> 200; 409 WRONG_STATE (twice / terminal); 403 AUTH_INVALID on commit mismatch (session -> `FAILED(PROTOCOL_ERROR)`) | §4.3.2 table, new `sas-reveal.schema.json` | 1.0 server answers 404; caps token `sas` tells senders in advance. |
| 6 | **`POST /pair`** (long request, up to 125 s, held until the inviter's user decides) | §4.3.2, new `pair-request/response` schemas | 404 on 1.0; cap `pair`. |
| 7 | **Error codes** `AUTH_INVALID` 401 (proof missing/stale/replayed/forged/mismatching fingerprints), `KEY_CHANGED` 403 (known deviceId, different key); `PIN_REQUIRED/PIN_INVALID/BLOCKED/INSUFFICIENT_STORAGE` become enforced; Contacts-only strangers get the plain `NOT_FOUND` envelope of an unknown route (no oracle, no new code) | §4.3.5 table, `error-envelope` enum, `LsErrorCode` | 1.0 clients map unknown codes to `INTERNAL` (retryable), so at most 3 harmless retries. |
| 8 | `POST /sessions` check order: IP block / contacts-only gate -> rate limit -> body size (4 MiB) -> **auth** -> shape -> 426 -> consistency -> sender-vs-proof match -> block list / KEY_CHANGED -> PIN -> 507 -> pending cap (3 per IP, 8 global; 429) -> BUSY | §4.3.4 | Same for 1.0 clients that reach it. |
| 9 | `X-LS-Chunk-SHA256` mandatory in secure mode (missing -> 400); stays optional in the plaintext profile so the Inc 1 conformance test remains valid | §4.3.4 step 7 | n/a |
| 10 | `kMaxSessionJsonBytes` 4 MiB for `POST /sessions` (D11) | §4.1, §4.3.4 step 2, `session-request` schema description | A 1.0 receiver answers 413 above 256 KiB. |
| 11 | `caps` tokens `sas`, `pair` | §4.2 | Unknown caps ignored. |
| 12 | **Discovery `bye` datagram** (D12); rule 8 text ("no goodbye datagram") replaced; `discovery-announce` schema gets a `oneOf` with a `bye` shape | §4.2 | Dropped by 1.0 decoders. |
| 13 | `libreshare://pair` URI with reserved `s` | §4.2 rule 6 | Unknown scheme path for 1.0 apps. |
| 14 | SAS formula replaced by D4 (commit, reveal, nonces) with published test vectors | §5 | n/a (1.0 never emitted a SAS). |

Docker e2e with mixed old/new (section 7, step l): a `legacy` service runs the plaintext profile (`--insecure-plaintext`, the faithful stand-in for an LSP/1.0 receiver because it serves exactly the 1.0 wire). Expected: new->legacy refused locally, legacy log shows 0 requests; legacy->new fails with `NO_CONNECTION` while the new receiver logs only an exception type; `--allow-insecure` (new->legacy) still works and is asserted so the escape hatch is documented behaviour, not an accident.

## 4. Requirements trace and tests (tests first; names, not code)

Layout: `packages/libreshare_core/test/{unit,security,conformance,integration}/` (new `security/` directory matches the traceability seed names), app tests under `apps/libreshare_app/test/`, CLI under `packages/libreshare_cli/test/`.

| Requirement | Proven by |
|---|---|
| FR-05 mutual authentication, pinned fingerprints | `unit/cert_factory_test`, `unit/crypto_primitives_test`, `unit/identity_proof_test`, `unit/mtls_handshake_test` (name kept from the seed; real sockets, TLS 1.3, both fingerprints equal on both sides), `security/pinning_test`, `security/mitm_test`, `integration/secure_two_engine_test` |
| FR-06 accept/reject, 120 s silence | `unit/permission_test`, `integration/secure_two_engine_test` (reject, timeout via short `permissionTimeout`), app `incoming_sas_test` |
| FR-10 acceptance (corrupted chunk resent; corrupted file => `FAILED(VERIFY_FAILED)`, partial removed) | `integration/corruption_e2e_test` (secure mode, fault-injecting `PeerClient` decorator flips one byte after the hash is computed) |
| FR-16 / NFR-04 (wrong certificate refused, wrong PIN x5 blocked, traversal contained) | `security/pinning_test`, `security/key_change_test`, `security/rate_limit_test`, `security/pin_test`, `integration/path_traversal_secure_test` (`../../etc/passwd` and a `..` relativePath through TLS+SAS), `security/oversize_test` |
| FR-18 Contacts-only part | `security/contacts_only_test`, `integration/contacts_only_engine_test`, app `visibility_contacts_test`, Docker e2e step |
| Threat table (spec §5) | MITM `security/mitm_test`; rogue spam `security/rate_limit_test`; replay `unit/identity_proof_test` + `security/sas_binding_test`; unauthorized download `security/token_test`; disk exhaustion `security/oversize_test` |
| Roadmap: `s=` reserved, nullable `K_pair` | `unit/pairing_test` (K_pair vector shared with Inc 6), `unit/device_registry_test` (unknown fields such as `kPairRef`, `peerAdvKey` survive a round trip) |
| Carried: goodbye, 4 MiB cap | `unit/goodbye_test`, `integration/goodbye_engine_test`, `security/oversize_test` (10,000 files accepted, 10,001 and 4 MiB + 1 refused with 413) |

### 4.1 Negative and security tests (the checklist the reviewer runs)

| Test file | Cases (test names) |
|---|---|
| `security/pin_test` | `no_pin_when_required_is_PIN_REQUIRED` · `wrong_pin_is_PIN_INVALID_and_counts_a_strike` · `correct_pin_accepted` · `non_six_digit_pin_is_400` · `expired_window_pin_is_PIN_INVALID` (fake clock) · `replayed_one_time_pin_is_PIN_INVALID` · `consumed_pin_looks_like_wrong_pin` (same body and status) · `contact_exempt_from_pin` · `pin_never_in_logs_or_error_messages` |
| `security/rate_limit_test` | `five_wrong_pins_block_ip_even_for_correct_pin` · `block_lifts_at_exactly_ten_minutes` · `other_ip_unaffected` · `global_25_failures_lock_pin_checks_and_rotate_pin` · `retry_after_header_present` · `eleventh_session_post_in_a_minute_is_429` (unchanged) · `fourth_pending_prompt_from_one_ip_is_429` · `ninth_global_pending_is_429` · `rejected_session_frees_the_pending_slot` · `rate_limit_runs_before_body_read` |
| `unit/identity_proof_test` | `valid_proof_verifies` · `tampered_{method,path,body,ts,nonce,serverFp,clientFp}_each_rejected` · `stale_timestamp_rejected` · `replayed_nonce_rejected` · `cert_hash_not_matching_claimed_fingerprint_rejected` · `non_p256_key_rejected` · `oversized_cert_or_header_rejected` · `10k_random_headers_never_throw` · `proof_for_server_A_rejected_by_server_B` (channel binding) |
| `security/pinning_test` | `pinned_peer_with_other_certificate_refused_before_any_http_byte` (raw server counts bytes = 0) · `expired_certificate_still_accepted_when_pinned` · `unpinned_first_contact_connects_and_reports_fingerprint` · `announce_with_other_fingerprint_does_not_override_pin` · `fingerprint_in_info_must_equal_certificate_hash` |
| `security/key_change_test` | `sender_refuses_receiver_key_change_with_PeerKeyChanged` (client exception type, distinct from `HandshakeException`) · `receiver_answers_KEY_CHANGED_403_to_known_deviceId_with_new_key` · `key_change_emits_event_and_never_auto_accepts_even_for_trusted` · `explicit_removal_then_sas_restores_flow` · `cli_exit_code_for_key_change_is_distinct` |
| `unit/sas_test` | `known_answer_vectors` (fixed fps+nonces) · `both_sides_compute_same_code` · `fingerprint_order_does_not_matter` · `leading_zeros_kept` · `reveal_with_wrong_nonce_rejected` · `any_input_change_changes_commit` · `nonce_length_enforced` · `10k_samples_roughly_uniform` |
| `security/sas_binding_test` | `relaying_mitm_detected_by_commit_mismatch_without_user_input` · `impersonating_mitm_gets_different_codes_on_each_side` (seeded) · `plain_hash_sas_is_grindable_but_commit_reveal_is_not` (documents finding 2; attacker must commit first, success rate stays <= 1e-4 over 10^4 seeded trials) · `receiver_cannot_accept_before_reveal` · `no_reveal_within_30s_fails_TIMEOUT` · `commit_present_means_no_auto_accept` |
| `security/mitm_test` | in-process TLS-terminating proxy with its own certificate: `pinned_sender_refuses_proxy` · `first_contact_relay_fails_at_reveal` · `proxy_cannot_replay_captured_proof_to_real_receiver` · `proxy_with_own_identity_never_gets_files_without_user_accept` |
| `security/downgrade_test` | `plaintext_peer_refused_when_tls_required_zero_bytes_sent` · `empty_fingerprint_announce_cannot_replace_pinned_device` · `tls_receiver_closes_plaintext_client_without_http_body` · `tls12_only_client_refused` (skips without `openssl`) · `client_never_retries_over_http_after_tls_failure` · `legacy_listed_but_send_requires_allow_insecure` |
| `security/contacts_only_test` | `stranger_get_info_is_404_identical_to_unknown_route` · `stranger_register_and_sessions_404_even_with_valid_proof` · `contact_with_proof_served` · `removed_contact_404_again` · `probe_from_untrusted_fingerprint_unanswered` · `no_mdns_no_periodic_announce` |
| `unit/permission_test` | `reject_gives_FAILED_REJECTED` · `120s_silence_gives_FAILED_TIMEOUT` (fake clock) · `accept_after_timeout_is_409` · `accept_races_timeout_exactly_one_wins` · `trusted_contact_autoaccept_off_by_default_still_prompts` · `autoaccept_only_with_proof_pinned_and_no_commit` · `blocked_fingerprint_403_BLOCKED_before_prompt` · `repeated_rejects_offer_block` (event only) |
| `security/log_hygiene_test` | records every `Logger` record at `Level.ALL` through pair, SAS send, wrong PIN x5, key change, bye, 10k-file session with sentinel values (PIN `424242`, pairing secret, private-key bytes, nonces, tokens, session ids); asserts none appears, no 64-hex run (fingerprints <= 16 hex), no base64url run >= 40 chars, error envelopes contain none either. Existing `_log.fine('session $sid ...')` in `file_receiver.dart` must shrink to an 8-char id prefix |
| `unit/{credential_store,device_registry,secret_store}_test` | create once / reload gives the same fingerprint; missing key with present certificate => `IdentityLost` (no silent regeneration); corrupt JSON => empty registry + `.corrupt` backup, never a crash; 0600 on POSIX; atomic write (kill between tmp and rename leaves the old file); LRU bound of 512 `known` entries; unknown JSON members survive |
| `unit/goodbye_test`, `integration/goodbye_engine_test` | `valid_bye_removes_peer` · `forged_signature_ignored` · `stale_or_replayed_bye_ignored` · `bye_for_unknown_peer_ignored` · `verification_budget_5_per_second` · Receive Off removes the device from the other list in <= 1 s (was <= 90 s) · LSP/1.0 decoder drops it |
| `unit/pairing_test` | `K_pair_vector` · `wrong_mac_rejected` · `second_use_of_S_rejected` · `expired_S_rejected` (fake clock) · `inviter_decline` · `S_erased_after_success` · `contacts_pinned_both_ways` |
| App (`flutter test`) | `incoming_sas_test` (SAS digits appear after `SasReady`; Accept disabled until then for unknown senders; verified-contact variant has no code; key-changed variant has no Accept) · `trust_settings_test` (list, remove, block, auto-accept toggle, own fingerprint replaces `fingerprintLater`) · `pin_settings_test` · `pair_screen_test` (QR payload has `s=`, never shown in a log) · `visibility_contacts_test` (option now enabled) · `notification_service_test` (routing; no SAS or file names on a locked-screen payload) · `device_card_trust_badge_test` |

## 5. Work breakdown (parallel subagents, strict file ownership)

Process rules: tests first and shown failing for the right reason; no two packages edit the same file; shared contracts are orchestrator-owned (CLAUDE.md); existing Inc 1/2 test files are never edited (new behaviour gets new test files; the one exception is the Q2 flip below, setup lines only, with approval). Effort numbers are person-day estimates, not measured.

### Wave 0 - orchestrator (about 0.75 d), before any package starts

1. `packages/libreshare_core/pubspec.yaml`: add `pointycastle: ^4.0.0` (only new core dependency); app: `flutter_secure_storage`, `flutter_local_notifications`, `flutter_foreground_task` (versions per `dart pub outdated`); then `dart pub get` and `dart analyze` must still be clean.
2. Contract edits (all orchestrator-owned files): `protocol.dart` (`kProtocolVersion '1.1'`, `kMaxSessionJsonBytes`, `kAuthHeader`, `kSasRevealTimeout`, `kPairTimeout`); `model/ls_exception.dart` (+`authInvalid`, `keyChanged`); `model/session_models.dart` (`SessionRequest.sasCommit`, `SessionStatus.sas`, pair DTOs); `model/events.dart` (+`SasReady`, `PeerKeyChanged`, `PinBruteForceSuspected`, `ContactChanged`; the app's `switch (e)` in `providers/transfers_provider.dart` must gain a default arm: tell P8); `server/incoming_transfer_handler.dart` (`createSession(..., AuthenticatedPeer? peer)`, `revealSas`, `pair`); `client/peer_client.dart` (`serverFingerprint`, `revealSas`, `pair`); new `security/contracts.dart` with the types below; barrel `libreshare_core.dart`; `test/helpers/api_fake_handler.dart` kept compiling (additive optional parameters); `apps/libreshare_app/lib/platform/platform_services.dart` (+`NotificationService`, `ReceiveHost`, `SecretStoreFactory` and fakes) and one-time stubs in `platform/platform_factory.dart` that call factory functions living in new files owned by P8/P9.
3. Contract sketch (signatures only, final shapes decided by the orchestrator):

```dart
final class AuthenticatedPeer { String fingerprint; Uint8List certDer; String? deviceId; }
enum PeerTrust { unknown, known, trusted, blocked }            // keyChanged is an overlay flag
abstract interface class SecretStore { Future<Uint8List?> get(String k); Future<void> put(String k, Uint8List v); Future<void> delete(String k); }
abstract interface class TrustStore { PeerTrustInfo classify(String deviceId, String fp); Future<void> pin(...); Future<void> block(String fp); Future<void> remove(String deviceId); Stream<void> get changes; }
abstract interface class IdentityProvider { DeviceIdentity get identity; Uint8List sign(String domain, List<int> msg); }
final class SecurityConfig { /* plaintext() | tls(identity, trust, pinPolicy, consentPolicy, allowPlaintext: false) */ }
final class IncomingSessionInfo { AuthenticatedPeer? peer; PeerTrust trust; bool keyChanged; String? sasCode; bool sasRequired; }
```

4. Docs skeleton: ADR 0004 (authentication model, replaces "mTLS" wording) and ADR 0005 (SAS commit/reveal), numbers chosen because design 02 reserves 0003.

### Wave 1a (parallel, 2-3 d)

| Pkg | Owns (files) | Tests it writes first | Depends on |
|---|---|---|---|
| **P1 Crypto core** (2.5 d) | `security/{crypto_primitives,der,cert_factory,identity_proof,sas}.dart` | `unit/{crypto_primitives,cert_factory,identity_proof,sas}_test`, `security/sas_binding_test` (primitives part); spikes S-A, S-B, S-C (pointycastle speed) with results in `docs/test-reports/inc3-spikes.md` | W0 |
| **P2 Storage + trust** (1.5 d) | `storage/{file_secret_store,credential_store,device_registry}.dart`, `security/trust_store.dart` | `unit/{secret_store,credential_store,device_registry,trust_store}_test` | W0 |
| **P7 Protocol docs + conformance** (1.5 d) | `docs/protocol/LSP-1.md`, `docs/protocol/schemas/*` (edits + new `auth-proof`, `sas-reveal`, `pair-*`), `test/conformance/lsp11_conformance_test.dart`, `docs/adr/0004*,0005*` | golden fixtures for `X-LS-Auth`, SAS vectors (computed by P1; P7 blocks on P1's vectors for the last 0.5 d), schema examples validate, error table equals §4.3.5 | W0, P1 vectors |

### Wave 1b (parallel, 2.5-3 d; start against fakes, switch to P1/P2 output as it lands)

| Pkg | Owns | Tests | Notes |
|---|---|---|---|
| **P3 Server** (2.5 d) | `server/api_server.dart` (TLS bind, contacts-only gate, auth step, new routes `/sas`, `/pair`, secure-mode chunk-hash rule, 4 MiB cap, `Date`), new `server/auth_guard.dart`, `security/pin_guard.dart`, `test/helpers/api_fake_handler.dart` | `security/{rate_limit,pin,token,oversize}_test`, `conformance/api_conformance_secure_test` (raw `HttpClient` over TLS: check order of section 3 item 8, 404 identity of unknown route vs stranger) | `ApiServer.stop` second-call behaviour re-verified (Inc 2 note) |
| **P4 Receiver / consent** (3 d) | `transfer/file_receiver.dart`, `security/{consent_policy,pairing_service}.dart` | `unit/{permission,pairing}_test`, `security/{key_change,sas_binding}_test` (receiver half), `security/log_hygiene_test` | owns the session state machine additions: sender identity, SAS state, trust classification, pending caps, free-space check stays |
| **P5 Client / sender** (2.5 d) | `client/api_client.dart`, `transfer/file_sender.dart` | `security/{pinning,downgrade}_test`, `unit/{api_client_tls,file_sender_sas}_test`, `integration/corruption_e2e_test` harness | `PeerKeyChanged`/`InsecurePeer` exception types live here; ApiClient attaches proofs; FileSender runs commit/reveal and emits `SasReady` |
| **P6b Discovery** (2 d) | `discovery/{announce_codec,multicast_discovery,peer_registry,subnet_scanner,peer_registrar,manual_peer}.dart` | `unit/goodbye_test`, `integration/goodbye_engine_test` (with P6a), scanner/registrar over HTTPS (new test files, e.g. `unit/subnet_scanner_tls_test`) | `bye` encode/decode/verify, `PeerRegistry.remove` + D1 seeding of the TOFU baseline, https probes with `fingerprint == hash(cert)` check, trust-aware probe replies, Contacts-only reply filter |

### Wave 2 (3 d)

**P6a Engine + CLI + receive** owns `engine/{libreshare_engine,discovery_config,security_wiring}.dart`, `receive/receive_controller.dart` (Contacts-only enabled; remove the `UnsupportedError`), `packages/libreshare_cli/lib/ls_cli.dart`. Tests: `security/{mtls_handshake,contacts_only,tofu}_test`, `integration/{secure_two_engine,contacts_only_engine,path_traversal_secure}_test`, `packages/libreshare_cli/test/cli_security_test.dart` (new file). New engine surface: `SecurityConfig` param, `identity`, `contacts`, `createPairInvite()/redeemPairInvite()`, `incomingInfo(sessionId)`, `trust(...)/block(...)/removeContact(...)`. New CLI: `ls identity show|rotate`, `ls contacts list|add --fp|remove|block`, `ls pair --show|--scan URI`, `--secure`/`--insecure-plaintext`, `--insecure-tofu`, `--allow-insecure`, `--pin`, `--identity-dir`; lines `SAS 482 913 peer=<alias> fp=<16 hex>` on both sides; distinct exit codes for key changed, insecure peer, PIN/auth/blocked, SAS aborted (numbers fixed by the tests).

### Wave 3 (parallel, 2-4 d)

| Pkg | Owns | Tests |
|---|---|---|
| **P8 App UI** (4 d) | `apps/libreshare_app/lib/{widgets,screens,providers,services,l10n_strings.dart}` except `platform/android/**`; new `platform/secret/**`, `platform/notification/**`; harness helpers in `test/helpers/` | the App rows of section 4.1; `flutter test` |
| **P9 Android spike** (2 d, section 6) | `apps/libreshare_app/android/**`, `lib/platform/android/**` | `test/platform/receive_service_host_test`, `receive_host_proxy_test`; CI `flutter build apk --debug` |
| **P10 Docker + CI** (1.5 d) | `tools/docker/**`, `tools/*.sh`, `.github/workflows/ci.yml`, `docs/test-reports/inc3-docker.md` | section 7 scenarios |

### Wave 4 - orchestrator close-out (1 d)

Full verification (section 9), mutation checks, Q2 flip if approved, `docs/traceability.md` (FR-05/06/16/18 part, NFR-04 part; propose "FR-22 Pairing and contacts" because design 02 reserves FR-19..21), CLAUDE.md gotcha line for Android (design 01 §6 asked for it), roadmap row, and the Outcome section below.

Dependency order: W0 -> {P1, P2, P7} -> {P3, P4, P5, P6b} -> P6a -> {P8, P9, P10} -> W4. Critical path about 11-13 working days; total effort about 27 pd (estimates).

### Definition of done, every package

Run from the repo root; read the exit code of the command itself, never of a pipe (`... | tail` hides failures: Inc 1 lesson).

```bash
source tools/env.sh
dart format --output=none --set-exit-if-changed <owned dirs>; echo "format=$?"      # 0
dart analyze --fatal-infos; echo "analyze=$?"                                       # 0
(cd packages/libreshare_core && dart test <owned test files>; echo "test=$?")       # 0, run 3 times, no flake
grep -RnE "package:flutter|dart:ui" packages/libreshare_core/lib; echo "grep=$?"    # 1 (no match)
```

plus: (a) the package shows its tests failing before the implementation, (b) one mutation check from section 9 for its area, (c) no file outside its ownership list changed (the orchestrator diffs the tree), (d) no `print`, no secret in logs (`security/log_hygiene_test` stays green). App packages add `(cd apps/libreshare_app && flutter test; echo "flutter=$?")`. P1 additionally records the spike timings in `inc3-spikes.md`.

## 6. Android `ReceiveService` - SPIKE package P9 (written here, only CI-built)

There is **no Android SDK on the dev box**: P9's code cannot be compiled or run locally; its Dart side is unit-tested with a mocked `MethodChannel`, and the APK is built only in CI (`flutter build apk --debug` must be green there). Real-device verification is a manual checklist in `docs/test-reports/inc3-android.md` (blank results, filled by the user). Consequence: P9 is **non-gating** for "Inc 3 done" except (1) Dart unit tests pass locally, (2) the CI APK build is green once a push exists; the decision is recorded in the Outcome section (a deliberate, stated exception to "N+1 only after tests pass", because no test can exist here).

- **Design (design 01 §4.3-4.5):** one `ReceiveService` foreground service, `foregroundServiceType="connectedDevice"` (prerequisite `CHANGE_WIFI_MULTICAST_STATE` already declared), 6 h default app-level window, `onTimeout(int,int)` implemented even though `connectedDevice` has no OS cap today (`stopSelf()` then `ReceiveController.platformTimeout()`), `START_NOT_STICKY`, notification with Stop / Extend 6 h, a separate normal-importance "Receiving ended - Resume" notification, `ReceiveTileService` + transparent `ResumeActivity` (visible-activity exemption), `BootReceiver` (opt-in `receiveOnBoot`, default off), `ExitHint` from `ApplicationExitInfo.REASON_USER_REQUESTED`.
- **Spike question 1, where the engine lives:** (A, recommended) a ~150-line custom Kotlin service that only holds the process alive and a cached `FlutterEngine` owned by the Application so the main isolate (engine, `ReceiveController`) survives the activity; (B) `flutter_foreground_task` 11.0.3 `TaskHandler` isolate hosting the engine and a `ReceiveHost` port proxy for the UI. Design 01 prefers B with A as fallback; I invert it for Inc 3 because B forces every UI call across isolates (`ReceiveHost` proxy plus event forwarding) and its isolate model is UNVERIFIED. Deliver A; keep the `ReceiveHost` interface (W0) so B can replace it.
- **Fallback ladder (explicit):** F0 `connectedDevice` service; F1 if `startForeground` throws or an OEM rejects it: `dataSync` with a 5 h 45 m window, no boot start, resume only with the app visible (restart rules in design 01 §4.4); F2 no FGS: receive only while visible, banner "Receiving only while LibreShare is open" (**today's behaviour**, so a failed spike regresses nothing).
- **Manifest delta (design 01 §4.5):** add `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, keep `FOREGROUND_SERVICE_DATA_SYNC` for F1, `RECEIVE_BOOT_COMPLETED`, `WAKE_LOCK`, service/receiver/tile/activity entries; **remove `android:usesCleartextTraffic="true"`** (the TODO in the Inc 2 manifest; UNVERIFIED whether dart:io consults it at all); never declare `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`; `ACCESS_LOCAL_NETWORK` only at targetSdk 37.
- **Manual checklist (user, later):** FGS starts from the toggle on Android 15/16; screen-off receive for 30 min with and without battery exemption (`adb shell dumpsys deviceidle force-idle`); Task Manager stop => `Paused(osStopped)`; tile resume; boot opt-in; incoming-prompt notification actions.

## 7. Docker e2e additions (`tools/docker/compose.yaml`, `e2e.sh`; P10)

Current topology (alice .240, bob .250, carol .230, tester .10 on one /24 bridge) stays. Add: `dave` (Contacts-only receiver, separate identity volume), `legacy` (plaintext profile), persistent identity volumes `*_id` so restarts keep fingerprints. New scenarios, each with a PASS/FAIL line and an exit-code check:

| Step | Asserts |
|---|---|
| f TLS transfer | `send --device alice` 20 MiB over TLS, byte-identical, no `.lspart`, no plaintext request seen by `tcpdump -A` for the file marker (NET_ADMIN already in `tester`) |
| g SAS agreement | sender and receiver print the same `SAS xxx xxx` (receiver run without `--auto-accept` using a here-doc `y`); a second send from a re-created sender identity prints a different code |
| h persistence + TOFU | restart bob with the same identity volume: sender still pinned (no SAS); recreate bob with a NEW identity volume but same deviceId: sender exits with the key-changed code, 0 bytes sent |
| i wrong PIN | carol with `--pin`; five wrong PINs from tester, sixth (correct) is `BLOCKED`; after the window lifts (time compressed by a test flag) the correct PIN works |
| j contacts-only | dave not listed by `devices`; `pair --show` on dave, `pair --scan` on tester through the `/sync` volume; dave now listed within 3 s; stranger container gets 404 on `GET /info` |
| k goodbye | carol Off => `devices --listen` on alice prints `LOST` within 1 s (previously up to 90 s) |
| l mixed old/new | the section 3 expectations (refused, 0 requests, closed connection, `--allow-insecure` works) |
| m throughput note | `tools/loopback_smoke.sh` in secure mode, ungated delta vs the plain 19 MiB/s baseline recorded in `docs/test-reports/inc3-docker.md` |

## 8. Risks and unknowns

| # | Risk / unknown | Handling |
|---|---|---|
| R1 | D1 premise (server rejects untrusted client certs) is UNVERIFIED | Spike S-A, 30 min; plan unchanged either way |
| R2 | pointycastle P-256 speed on Android/AOT UNVERIFIED | Spike S-C numbers; budget in D2; fall back to per-session signing and proof caching |
| R3 | `usePrivateKeyBytes` PKCS#8 EC, client callback on IP mismatch, TLS 1.3 minimum on all platforms UNVERIFIED | Spike S-B; if PKCS#8 fails, emit SEC1 `EC PRIVATE KEY` PEM |
| R4 | Own DER builder/parser is security-sensitive | strict length caps, no indefinite length, fuzz test (10k mutations of valid certs never throw past the boundary), `openssl` oracle test |
| R5 | Scope: Inc 3 is the biggest increment so far (about 27 pd for one sprint of parallel agents) | Cut order if late: notification action buttons (tap opens dialog) -> `POST /pair` (keep QR + `s=`) -> `bye` -> Windows keystore (file store only) -> Android F0 (ship F2); never cut D1/D4/D5, the key-change refusal, log hygiene, or Contacts-only 404 |
| R6 | Contacts-only stealth is best effort: probe replies trust an unauthenticated fingerprint claim, so anyone who knows a contact's fingerprint can learn the device exists. HTTPS stays closed to strangers (404) | Documented; signed announcements are a later option (Inc 6 signs presence records anyway) |
| R7 | Unknown hardware clocks: proof window +-120 s may reject phones with bad time | `Date`-header skew correction (D9, UNVERIFIED `Date` always present); clear UI error |
| R8 | Plaintext default of library/CLI until Q2 is approved | Plaintext profile refuses non-loopback bind in the CLI once flipped; app is secure from day one |
| R9 | `flutter_secure_storage` Windows mechanism and Linux "no keyring" behaviour unknown [S7] | File store is the default on desktop; Android only in Inc 3 |
| R10 | Notification actions on Linux/Windows depend on the notification server / package identity (design 01 §3, §2.2) | Dialog is the source of truth; actions are best effort |
| R11 | LSP-1 §4.3.4 step 7 says the chunk-hash header is mandatory from Inc 3 but an Inc 1 conformance test accepts a missing one | Mandatory in secure mode only (section 3 item 9), no old test edited |
| R12 | Relay attack on SAS (user compares codes with the wrong person) is not preventable | Consent screen shows alias, platform, address and verified-contact badge; documented in the threat table |
| R13 | Windows `FileMode.append`+`setPosition` still unverified (Inc 1 carry) | Windows CI job; not touched here |

## 9. Criteria for declaring Inc 3 done (all by real exit codes, on the dev box unless marked CI)

```bash
source tools/env.sh
dart pub get;                                                       echo "pub=$?"       # 0
dart format --output=none --set-exit-if-changed .;                  echo "format=$?"    # 0
dart analyze --fatal-infos;                                         echo "analyze=$?"   # 0
(cd packages/libreshare_core && dart test);                         echo "core=$?"      # 0; baseline 975 passed + 1 skipped (Inc 2), expect about +180 new, zero old tests changed
(cd packages/libreshare_cli  && dart test);                         echo "cli=$?"       # 0; baseline 41, plus cli_security_test
(cd apps/libreshare_app      && flutter test);                      echo "app=$?"       # 0
bash tools/loopback_smoke.sh 100 <free port>;                       echo "smoke=$?"     # 0 plaintext profile still byte-identical (no regression vs 19.2 MiB/s)
bash tools/loopback_smoke.sh 100 <free port> --secure;              echo "smoke_tls=$?" # 0 (flag added by P10); rate recorded, not gated
docker compose -f tools/docker/compose.yaml up --build --abort-on-container-exit --exit-code-from tester; echo "e2e=$?"   # 0, every step f..l PASS
grep -RnE "package:flutter|dart:ui" packages/libreshare_core/lib;   echo "grep=$?"      # 1
```

Plus: each new test file run 3 times, no flake; `git`-free diff check that no Inc 1/2 test file changed except the approved Q2 setup lines; **mutation checks** (each must turn at least one named test red, then be reverted): M1 skip the pin comparison in `ApiClient`'s callback; M2 drop `serverFp` from the signed text; M3 let SAS ignore the nonces; M4 count PIN strikes on success; M5 log the PIN; M6 let `accept()` ignore SAS readiness; M7 answer 403 instead of 404 to Contacts-only strangers; M8 skip the `bye` signature check; M9 auto-accept when a commit is present; M10 regenerate identity silently when the key is missing. CI (when a push exists): `core`, `app` Linux build, Android `flutter build apk --debug`, Windows build, `e2e-docker` all green. Android on-device checklist and the Q2 flip are tracked separately and do not block the verdict unless the user says so.

## 9b. Requests carried into P6a from the Docker install work (2026-11-04)

From `docs/test-reports/docker-install.md` (agent DK): (1) `ls receive --advertise-ip ADDR` (what other devices learn from `/info` addrs, announces and `peer-link`; `peer-link --ip` is only a bind address, so a container behind NAT cannot name its host's LAN IP; the install scripts currently rewrite `ip=` in the printed link); (2) the persistent CLI identity/state directory already planned as `--identity-dir` must also work for the container (`/config`), after which the install scripts can print full `id=` links; (3) cosmetic: `info` and `devices` throw an unhandled `FileSystemException: Broken pipe` when stdout closes early. Items 1 and 2 are in scope for P6a; item 3 is a one-line fix there.

## 10. Out-of-scope findings carried over that Inc 3 touches

1. **`PeerRegistry` cannot remove a peer** (a Receive-Off device lingers up to 90 s): fixed here by D12 (`bye` + `PeerRegistry.remove`), owner P6b; acceptance "gone from the other list in <= 1 s".
2. **256 KiB JSON cap vs 10,000 files**: fixed by D11 (4 MiB for `POST /sessions`), tests in `security/oversize_test`; LSP-1 §4.1 + `session-request` schema updated together.
3. **Subnet scan probes only the default port**: not fixed (probing 53319..53327 multiplies scan cost); the scan moves to HTTPS with the fingerprint-equals-certificate check; peers on a fallback port are still found by multicast, register, links.
4. **Contacts-only was refused (`UnsupportedError`)** in `ReceiveController`: enabled here (design 01 §1.3).
5. **`ApiServer.stop()` second call**: Inc 2 reported it as a no-op; the current code escalates a pending graceful stop. P3 re-verifies with `unit/api_server_stop_test` before touching the file.
6. **CLI random device id per run** (finding 6): persistent identity directory.
7. **Docker multicast timings** were measured after Inc 2 (`docs/test-reports/inc2-docker.md`); Inc 3 adds steps but does not re-measure them.
8. **Windows append+seek**, **AOT hashing for NFR-02**: remain Inc 4 / Windows CI items.

## 11. Questions for the user (only genuine decisions)

- **Q1 (veto, default proceed):** accept the spec amendment "TLS server authentication + signed client proof" instead of TLS client certificates (finding 1, D1), and the SAS commit/reveal amendment (finding 2, D4)?
- **Q2 (blocks the default flip, CLAUDE.md says ask):** flip the **CLI default to TLS**, adding `--insecure-plaintext` to the setup lines of the two Inc 1/2 CLI test files (`cli_loopback_test.dart`, `cli_commands_test.dart`), `tools/loopback_smoke.sh` and the existing Docker services? Assertions stay untouched. Without approval the CLI keeps the plaintext default and only the app is secure by default. Library constructors keep plaintext defaults either way (no other old test changes).
- **Decisions recorded 2026-11-04.** Q1: accepted by the orchestrator (the user did not veto). Q2: the user delegated it ("whatever u think") and the orchestrator decided **yes: the CLI defaults to TLS**. Rationale: a plaintext-default CLI could not talk to the secure-by-default app, and the CLI would otherwise be the one insecure entry point. Scope of the acceptance-test edit is limited to *setup lines*: add `--insecure-plaintext` where `cli_loopback_test.dart`, `cli_commands_test.dart`, `tools/loopback_smoke.sh` and the Docker services start a receiver or sender; **no assertion, expected value or threshold may change**, and the diff of those files must show only that flag. The Inc 1 loopback acceptance command in CLAUDE.md keeps working by passing the flag.
- No other product questions: PIN default off, auto-accept for contacts off, no HTTP fallback, Windows keystore later, Android spike non-gating are sensible defaults.

## 12. Outcome / deviations (DRAFT 2026-11-05, written before the P6a gate; items marked `[FILL]` need measured data at close, same style as `inc2.md`)

**Scope note.** On 2026-11-05 the user cut the target to an MVP (`docs/plans/mvp.md`). Inc 3 is therefore closed *for the MVP*: P1-P7 and P6a (engine + CLI wiring) are in; P9 (Android `ReceiveService`) and P10 (extra Docker e2e) are **deferred, not dropped**. Section 9's `--secure` smoke flag belonged to P10 and does not exist; the CLI defaults to TLS instead (Q2).

- Done and proven (commands + exit codes + counts): `[FILL]` after the P6a gate: format, analyze, core, CLI, app, loopback smoke, grep-no-flutter (section 9 block, minus the P10 lines). Last measured before P6a (2026-11-05): core 2349 passed / 1 skipped with only the nine P6a files red, app 249 passed. Building blocks P1 263 tests, P2 215 tests, P7 40 known-answer vectors + 67 PIN-shape tests.
- Spike results S-A, S-B, S-C: see `docs/test-reports/inc3-spikes.md` (not re-measured here). The Android spike package P9 was not run (deferred).
- Deviations from this plan and why:
  1. `kProtocolVersion` stays `'1.0'`; the secure profile reports `kProtocolVersionSecure = '1.1'` (additive; plaintext peers unchanged).
  2. Security is added through **capability interfaces** (`SecureTransferHandler extends IncomingTransferHandler`, `SecurePeerClient extends PeerClient`) instead of changing the shared interfaces; schemas live in `schemas/lsp11/`.
  3. **No sender-side SAS gate**: the receiver's Accept is the human comparison of the two 6-digit codes; the sender shows its code while it waits.
  4. **507 INSUFFICIENT_STORAGE** is also returned for a missing/unwritable download folder (both profiles).
  5. Receiver **idle timeout** deferred to Inc 4 (inc2 follow-up 7).
  6. A **Contacts-only device multicasts nothing of its own** (no announce/probe/bye/mDNS); a malformed `X-LS-Auth` is a stranger on every route (404), `/pair` exempt.
  7. A pinned registry entry is **unchanged** by an empty or different fingerprint in an announce; only a different non-empty one raises the key-changed flag.
  8. The secure subnet scanner ignores a custom `InfoProbe` and never follows redirects; a reset TLS handshake is `SocketException`/`NO_CONNECTION`, `InsecurePeer` only when the TLS error carries an `osError`.
  9. An absolute `relativePath` is re-rooted inside the download dir (Inc 1 behaviour kept); only `..` is rejected.
  10. A malformed `pin` (not exactly six ASCII digits) is **400 with no strike** (secure profile). `PinGuard`: 5 failures/IP/10 min block, 25 global lock + rotate, one-time PIN consumed atomically.
  11. `BlockSuggested` event after 3 user rejects of the same fingerprint within 10 min; it **never auto-blocks**.
  12. The CLI **defaults to TLS** (user delegated Q2: "whatever u think"); `--insecure-plaintext` is added to *setup lines only* in the two CLI tests, `tools/loopback_smoke.sh`, `tools/docker/**`, `deploy/docker/**`. `[FILL]` confirm by diff against `pre-flip` snapshots that nothing else changed.
  13. New CLI exit codes 80 key changed, 81 insecure peer, 82 PIN/auth/blocked/bad pair secret, 83 SAS aborted, 84 identity lost.
  14. Windows uses the **file secret store** (no Windows keystore) for the MVP.
- Bugs found and fixed: `[FILL]` list from the per-package review notes (`inc3-p3-tests.md` ... `inc3-p6b-tests.md`, `inc3-p7-drift.md`); the Inc 2 AE defects are routed in `inc2-followups.md` (4 -> P6b done, 6 -> P4 507 done, 7 -> Inc 4, rest -> F3/P9).
- Mutation check results: about 180 mutations over P3-P6b reviews, run in scratch clones; every surviving mutation got a new test file (details in the package test notes). `[FILL]` map M1-M10 of section 9 to the named red tests; the P6a review adds its own.
- Android: emulator verified (Android 15) with the Inc 2 build; the secure build still has to be re-run through `tools/android_emulator_smoke.sh` (packaging card B3). No real phone yet. CI build status: no push exists (standing instruction), so CI and the Windows build have not run.
- Known limits carried forward (not fixed here): no connection cap on the server (slow-loris style load); forged `bye` datagrams can consume the 5/s verify budget; the `_certs` LRU can be flushed by a flood of distinct peers; distinct fixed messages for binding vs MAC failures (low); the 10,000-file 413 is applied after authentication; Contacts-only greeting (`_greetContacts`) is one-shot with no retry/UDP fallback and misses a peer that restarts while still listed with the same key (post-MVP, no test yet); `FileReceiver.getSession` held polls for IN_PROGRESS sessions against LSP-1 4.3 (the engine hid it with an override; fix = Wave C card C1); NFR-02 throughput (about 30 MB/s) deferred to Inc 4; `deploy/install.ps1` and all Windows code have never been executed or compiled on Windows.
- Hand-over to Inc 4 (candidate hook must carry the pinned fingerprint; `ApiClient` pin API; D2 session store; TLS cost in the throughput profile) and Inc 5/6/7 (identity-signing helper, `K_pair` slot, `peerAdvKey` passthrough, LSP 1.2 naming): unchanged from the plan above; P9 and P10 are additional hand-overs.

## Sources

- [S1] Local Dart SDK 3.13.7 (`.toolchain/flutter/bin/cache/dart-sdk/lib/`): `io/secure_socket.dart` (server `secureServer`/`bind` take `requestClientCertificate`/`requireClientCertificate`, no `onBadCertificate`; `X509Certificate.der/pem/sha1`), `io/secure_server_socket.dart` (`SecureServerSocket implements ServerSocketBase`), `_http/http.dart` (`bindSecure` has only `requestClientCertificate`; `listenOn(ServerSocket)`), `_http/http_impl.dart` (`HttpRequest.certificate`), `io/security_context.dart` (PEM/PKCS12, `minimumTlsProtocolVersion`, `setClientAuthorities`).
- [S2] https://raw.githubusercontent.com/dart-lang/sdk/main/runtime/bin/secure_socket_filter.cc (fetched 2026-11-04; server `SSL_set_verify(PEER)` with `nullptr` callback; client sets `X509_VERIFY_PARAM_set1_host/set1_ip_asc`; `SSLCertContext` not shown).
- [S3] https://dart.googlesource.com/sdk/+/stable/tests/standalone/io/https_client_certificate_test.dart (server trusts `client_authority.pem`; no untrusted-client case).
- [S4] https://pub.dev/packages/cryptography (2.9.0, Apache-2.0; "no pure Dart implementations of the NIST elliptic-curve algorithms").
- [S5] https://pub.dev/packages/pointycastle (4.0.0, MIT, deps `collection`, `convert`, ECDSA signing and key generation listed).
- [S6] https://pub.dev/documentation/basic_utils/latest/basic_utils/X509Utils/generateSelfSignedCertificate.html and https://raw.githubusercontent.com/Ephenodrom/Dart-Basic-Utils/master/lib/src/X509Utils.dart, `pubspec.yaml` (5.8.2; CSR-driven; deps `http`, `logging`, `json_annotation`, `pointycastle`, `archive`).
- [S7] https://pub.dev/packages/flutter_secure_storage (11.2.0, BSD-3-Clause; Linux needs libsecret and a keyring, Android minSdk 23, Windows mechanism not named).
- Repo facts: `api_server.dart:36` (`kPeerCertificateContextKey`), `api_client.dart:33-51`, `libreshare_engine.dart:463,480`, `subnet_scanner.dart:43-61`, `peer_registry.dart` (TOFU baseline), `file_receiver.dart` (`accept/reject/permissionTimeout/_checkFreeSpace`), `ls_cli.dart` (`_selfFrom`), `incoming_transfer_dialog.dart` (`sas-placeholder`), `AndroidManifest.xml` (Inc 2 TODOs), `tools/docker/compose.yaml`, design docs 01-04.
