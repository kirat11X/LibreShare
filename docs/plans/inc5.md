# Increment 5 - Internet link: tunnel, share link/QR, end-to-end encrypted pull (Sprint 5)

Status: **PLAN. GROUNDWORK ONLY authorized by the user on 2026-11-06 ("INC 5 WILL BE DONE BY GEMINI FOR GROUND WORK"): spikes S5-A..E and Wave 1a (tunnel_crypto, share_link, secret_redactor) as patches, see `MODULE_H_PROMPT.md` and `inc5-seams.md`; Waves 0, 1b-4 not started.** Written by the orchestrator, 2026-11-06 11:54:29 (real `date`). No code, no tests and no builds were run for this document except the read-only `ls`/`grep` checks listed in section 0.
Sources: spec section 12 Increment 5, section 7 (tunnel fallback), section 4.5 / 5 / 6; `docs/design/04-link-qr-and-free-internet-paths.md` (the main source; its decisions D1-D9 and findings F1-F13 are binding unless section 2 says otherwise); `docs/roadmap.md` (Inc 5 amendments); `docs/plans/post-mvp-plan.md` Wave 4; `docs/protocol/schemas/tunnel-offer.schema.json`; `CLAUDE.md`.
Evidence tags: **UNVERIFIED** = not confirmed by a source I read or a run; each one has a spike or a test that settles it. Cost rule: everything is $0 for users and maintainers. Effort numbers are ESTIMATES (person-days, one human; agent-run differs).

## 0. Findings that change the plan (read first)

Verified by `ls`/`grep` on 2026-11-06:

1. **Increment 5 cannot start yet.** CLAUDE.md and spec section 12: N+1 starts only when N's acceptance tests pass. Increment 4 (ladder, resume, NFR-02) is a plan only (`docs/plans/inc4.md`); `lib/src/connection/`, `tunnel/`, `session/` and `monitor/` are **empty directories** (0 files each). The `TunnelConnection` of this increment is a `Candidate` of the Inc 4 ladder and needs its interface.
2. **A placeholder for the tunnel already exists.** `SessionRequest.tunnelOffer` (`model/session_models.dart`, `TunnelOffer`), its JSON schema `docs/protocol/schemas/tunnel-offer.schema.json` (required: `provider`, `url` (https, with `/t/<token>`), `keyB64` (32 bytes), `expiresAt`) and the pass-through in `file_sender.dart:358` / `manifest.dart:112` exist. Nothing produces or consumes it. The schema says `keyB64` is a per-session AES-256-GCM key; design 04 section 3.2 turns it into the **root key** `k` for HKDF subkeys, so the schema text and LSP-1 section 4.5 change together (section 3).
3. **No AES-GCM primitive exists in core.** `security/crypto_primitives.dart` has `hmacSha256` and `hkdfSha256` (RFC 5869, built on package `crypto`); `packages/libreshare_core/pubspec.yaml` depends on `crypto`, `pointycastle`, `shelf`, `shelf_router`, `logging` and **not** on `cryptography`, which the spec and design 04 assume. Options: `pointycastle` `GCMBlockCipher` (already a dependency, pure Dart, speed **UNVERIFIED**) or adding `cryptography` (a `pubspec.yaml` change, orchestrator-only). Spike S5-A decides with a measurement.
4. **Speed is the real risk for the tunnel path.** The Lead's profile (`docs/test-reports/inc4-spikes.md`, claim not yet re-measured by me) says pure-Dart hashing dominates the transfer; end-to-end AES-GCM on 4 MiB chunks adds a second CPU-bound pass on both ends. The MVP loopback measured 17.9 MiB/s plaintext (`docs/test-reports/mvp-acceptance-secure.md`).
5. **The test harness pieces are only partly there.** `FakeTunnelProvider` does not exist (CLAUDE.md already names it and `LS_TUNNEL_LIVE=1`). The Docker compose has one network (`lan_net`); `inet_net` and the cut-both-local-nets scenario do not exist. A `FaultyTcpProxy` test helper was added to the real tree by the Lead on 2026-11-06 (`packages/libreshare_core/test/helpers/faulty_tcp_proxy.dart`); it is **not yet accepted** (see `docs/test-reports/gemini-claims-verification.md`).
6. **The app has no deep-link handler.** `apps/libreshare_app/lib/platform/` holds `android`, `autostart`, `tray`, `window`, `environment` and the mDNS backend only. `mobile_scanner` is already a dependency (QR scanning).
7. **Firewall range.** User-facing docs and installers use TCP 53318-53327. Direct-origin ports (53330-53349) belong to Inc 5b, so this increment leaves the range alone.
8. **Android foreground service** moved out of Inc 5 (roadmap amendment for Inc 3; Module F card F4 is a draft, unverified). Inc 5 only needs "receive a link" on Android, which is the app in the foreground.

## 1. Scope

**In (design 04 section 5.4, "Inc 5 tightened"):**
- `security/tunnel_crypto.dart`: HKDF purpose subkeys (`sid`, `manifest`, `data`, `ack`), random 96-bit nonces sent in band, canonical length-prefixed AAD, 2^24-seal cap per `k`, `X-LS-Claim` SAS.
- `server/tunnel_origin_server.dart`: loopback origin, routes `GET /t/{token}` (static, no side effect), `GET .../manifest`, `GET .../f/{fid}/c/{i}`, `POST .../ack`, 401/410 rules, limits (<= 8 concurrent per token, <= 32 total, 60 s write timeout, byte budget 2 x size x receivers), redacting logger, headers (`Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `application/octet-stream`).
- `share/` module: `link_share.dart` (state machine, modes 1 / N / anyone, claim binding, one-time = one authenticated completion, expiry with injectable `Clock`), `share_link.dart` (codec, 2 KiB cap, SSRF and host validation), `share_store.dart` (persists `shareId`, never `k`).
- `connection/origin_pull_connection.dart` + `tunnel_connection.dart` (receiver side: manifest, chunks, sealed ack, resume by `shareId`), plugged into the Inc 4 `Candidate` interface.
- `tunnel/`: `TunnelProvider` / `TunnelHandle` interfaces, `FakeTunnelProvider` (in-process reverse proxy with 429 above 200 in flight, request-body cap, latency/loss knobs, **capture buffer**, **hostile mode**), `ManualUrlProvider`, `CloudflaredProvider` (+ `binary_installer`, `process_supervisor`, `cloudflared_versions` with pinned SHA-256, clean HOME, never `--allowed-mail`), `ZrokProvider` last.
- UX: "Create link" and "Receive from link" in the app and the CLI (`ls link`, `ls receive-link`), deep links (`libreshare://r?...`), sleep inhibitor while a share is live, static landing page (`site/`, optional for app receivers).
- Docs: LSP-1 section 4.5 rewrite, schemas, conformance vectors, `docs/user/guide.md` section, Settings terms notice.

**Out:** direct IPv6 / UPnP / NAT-PMP / PCP tiers and "Hide my IP" (Inc 5b), browser WebCrypto receiver, bore/ssh providers, Android as a tunnel host (Inc 5c), rendezvous (Inc 6), any paid service or account the maintainers must operate.

## 2. Decisions to settle before coding

| # | Decision | Recommendation / how it is settled |
|---|---|---|
| D1 | AES-GCM implementation | Spike S5-A: measure `pointycastle` GCM on 4 MiB chunks in a worker isolate vs `cryptography` (pure Dart). Pick the faster one that needs no new native code. If a new dependency is needed, the orchestrator edits `pubspec.yaml` (Wave 0). |
| D2 | Link format | Design 04 section 2.1 unchanged for v1: https landing URL + fragment `v,h,t,k,m,e,n,fp`; `d` and `pin` are **parsed and ignored** in Inc 5 (reserved for 5b). `libreshare://r?` carries the same fragment. |
| D3 | Which sessions use the tunnel | (a) **Known-peer fallback**: `tunnelOffer` travels inside the mTLS `POST /sessions`; pre-warmed for sessions > 50 MB when "internet fallback" is on. (b) **Link share**: its own session kind, the sender publishes and the receiver pulls (design 04 D3). Both use the same origin server and crypto. |
| D4 | Default provider and consent | Cloudflare Quick Tunnel, behind a **first-use consent screen** that states "no uptime guarantee, for testing and development, the provider sees IPs, sizes and timing, never contents". zrok is opt-in (token). USER DECISION (section 11, Q1). |
| D5 | cloudflared delivery | Download on first use with a pinned SHA-256 (roadmap default 6). Bundling is a later packaging decision (section 11, Q2). |
| D6 | One-time semantics | One authenticated completion (sealed final ack), never "N GETs" (roadmap amendment). |
| D7 | Protocol version | Additive change to LSP/1.1 documented as LSP/1.1 section 4.5 + new schemas; no change to existing required fields. If the reviewer finds a breaking change, STOP and ask. |
| D8 | Tests of the crypto | RFC 5869 vectors for HKDF; NIST GCM vectors; shared JSON vector file (`test/conformance/fixtures/tunnel_crypto_vectors.json`) so a later JS receiver can reuse it. |
| D9 | What counts as "live" | One recorded Quick Tunnel transfer with the Dart client (`LS_TUNNEL_LIVE=1`) from a normal network; result in `docs/test-reports/inc5-live.md`. Needs outbound internet and the user's or the orchestrator's go-ahead (**UNVERIFIED** whether this container has it; S5-B checks without downloading anything). |

## 3. Protocol changes (LSP-1.md + schemas + conformance tests change together; orchestrator-owned)

1. LSP-1 section 4.5 "Crypto" and spec section 5 "Tunnel E2E": replace by design 04 section 3.2 (subkeys, random nonce `nonce || ciphertext || tag`, AAD = `"LSP1" || purpose(1) || shareId(16) || u32 fileIndex || u64 chunkIndex || u64 plaintextLen`, purposes 1 manifest / 2 chunk / 3 ack, manifest at `fileIndex = 0xFFFFFFFF`).
2. LSP-1 section 4.5 "Link": the format of design 04 section 2.1; `s=` dropped (derived `shareId`).
3. Origin route table: add `GET /t/{token}`, `X-LS-Claim`, 410 after revoke, the security headers, the limits. Ack and final-ack plaintext carry `{fid,idx}` / `{final,verified}`.
4. `tunnel-offer.schema.json`: description of `keyB64` becomes "root key k"; optional `m`, `candidates` (parsed, unused until 5b). New schemas for the sealed manifest, the ack and the final ack.
5. CLAUDE.md rule "Never log ... tunnel URL fragments" becomes "... tunnel URL fragments or tokens" (orchestrator edit at Wave 0).
6. Windows firewall: unchanged in this increment (decision in section 0, item 7).

## 4. Requirements trace and tests (names, not code; tests first)

| Req | Test (file) | Layer |
|---|---|---|
| FR-14 | `test/integration/tunnel_fallback_test.dart` (two engines + `FakeTunnelProvider` + `FaultyTcpProxy` cut the local path; transfer completes byte-identical); Docker step `m)` with `inet_net` (both local nets cut) | integration + e2e |
| NFR-04 | `test/security/e2e_ciphertext_test.dart` (capture buffer of the fake provider never contains the plaintext marker); Docker capture at the origin | security |
| NFR-06 | `test/unit/connection_tier_test.dart` (tunnel not started while a local tier is healthy; pre-warm only above 50 MB) | unit |
| Crypto | `test/unit/tunnel_crypto_test.dart` (RFC 5869 + NIST vectors; tamper, wrong AAD, swapped chunk, wrong purpose; 100k seals with no repeated nonce; an ack cannot decrypt as a chunk; cap at 2^24) | unit, security-critical |
| Link | `test/unit/share_link_test.dart` (round trip, size, unknown params ignored, > 2 KiB rejected, IP literal / userinfo / port != 443 / loopback / RFC1918 / link-local / 100.64/10 host rejected = SSRF) | unit |
| Share state | `test/unit/link_share_test.dart` (modes 1 / N / anyone, claim binding, second claimant 409, one-time = authenticated completion, expiry with fake `Clock`, byte budget revokes, revoke -> 410) | unit |
| Origin | `test/security/origin_limits_test.dart` (9th concurrent request on a token refused, 33rd overall refused, slow-read client cut after 60 s with fake clock, 300 slow clients cannot starve one real client) | security |
| Token | `test/integration/token_lifecycle_test.dart` (401 after COMPLETED / expiry, 410 after revoke) | integration |
| Hostile provider | `test/security/hostile_provider_test.dart` (flipped bits, swapped / replayed / dropped chunks, replayed old acks => `FAILED(VERIFY_FAILED)` or clean retry, never a wrong file) | security |
| Resume | `test/integration/link_resume_test.dart` (kill receiver mid-way, same `k`, new link, only missing chunks) | integration |
| Logs | `test/security/log_hygiene_tunnel_test.dart` (no token, no fragment, no `k`, no `/t/<token>` path in any log line of a full run, redacting logger unit test) | security |
| Cloudflared | `test/unit/cloudflared_provider_test.dart` (argv never contains `--allowed-mail`; wrong SHA-256 refuses to run; stale pidfile killed at start; URL parsing from fake process output; 429 / 1015 back-off 10 s / 30 s) with a fake process | unit |
| Live | `test/live/cloudflared_live_test.dart` gated by `LS_TUNNEL_LIVE=1`, never in the default run | manual |
| CLI | `packages/libreshare_cli/test/link_test.dart` (`ls link` prints a link, `ls receive-link` downloads via the fake provider) | CLI |
| App | widget tests with keys: Create link sheet, expiry countdown, per-receiver rows, Stop sharing, Receive from link (paste), consent card, error texts | app |

### 4.1 Negative checklist (a reviewer runs these; each must be a named test)
Link with `h` = IP literal; link with `d=127.0.0.1:1` (ignored in Inc 5, must not connect); link of 3 KiB; token of wrong length; claim header missing / reused by a second receiver; ack sealed under the data key; chunk replayed under another index; manifest replayed after a re-seal; file edited while shared (hash mismatch); origin reached from a non-loopback source; `Host` header spoofed; provider returns 200 with HTML (captive portal) instead of ciphertext; cloudflared exits mid-transfer (`TunnelLost`, resume path); two shares at once; stop sharing during a download; sleep inhibitor released after the share ends.

## 5. Work breakdown (roles per CLAUDE.md; strict file ownership; tester red -> coder green -> different verifier; security-critical packages also get a second tester)

**Gate before Wave 0:** Inc 3 closed (`inc3.md` section 12 filled, mutation sweep M1-M10 re-verified by me), Inc 4 accepted by section 9 of `inc4.md`, post-mvp Wave 1 done, user answers to section 11 Q1-Q4.

- **Spikes (first, 0.5-1 d each, results in `docs/test-reports/inc5-spikes.md`):** S5-A AES-GCM throughput (pointycastle vs cryptography, worker isolate, 4 MiB chunks, AOT and JIT). S5-B can this machine reach `trycloudflare.com` and the Cloudflare release host (DNS + TCP 443 only, no download). S5-C re-fetch the Cloudflare Quick Tunnel and zrok pages and record limits, terms and the `--allowed-mail` status with the fetch date. S5-D name and checksum layout of the current `cloudflared` and `zrok` release assets (read the release metadata only). S5-E redacting logger design: which logging path (`package:logging` handler, `shelf` access log) can see a path with a token.
- **Wave 0 (orchestrator, about 1 d):** `docs/plans/inc5-seams.md` (interfaces of design 04 section 5.2 as Dart signatures; `OriginCandidate`), contract files (`tunnel_provider.dart`, share model types), LSP-1 + schema + vector-file changes of section 3, CLAUDE.md rule, `pubspec.yaml` if D1 needs it.
- **Wave 1a (parallel, 3-4 d):** `tunnel_crypto` (T high, C medium, V high, second T high); `share_link` codec + validator (T, C medium, V); redacting logger (T, C low/medium, V).
- **Wave 1b (parallel, 4-5 d, after Wave 0 and S5-A):** `tunnel_origin_server` + limits (security-critical: second tester); `FakeTunnelProvider` with capture and hostile mode.
- **Wave 2 (5 d):** `link_share` state machine; `origin_pull_connection` / `tunnel_connection` on the Inc 4 `Candidate` interface; `share_store`; token lifecycle and resume integration tests.
- **Wave 3 (parallel, 5-6 d):** `cloudflared_provider` + installer + supervisor (fake process tests first); `manual_url_provider`; `zrok_provider` last; CLI `link` / `receive-link`; app screens, deep links, sleep inhibitor (app files only, widget tests).
- **Wave 4 (orchestrator close-out, 2 d):** Docker `inet_net` compose and step `m)`, whole-suite gate, mutation sweep on crypto / origin / link guards, docs (guide, Settings notice, `LSP-1.md`), live test with the user, `inc5.md` section 12.
- **Definition of done, every package:** new tests 3x green alone; analyze and format clean; core still free of Flutter imports; no log line with a token or fragment; mutation table (remove each guard -> the named test red); a different agent reviewed the diff; no existing test edited.

## 6. Effort (ESTIMATE, person-days; design 04 section 5.4: about 22 pd for the whole increment)

| Item | pd | Confidence |
|---|---|---|
| tunnel_crypto + vectors | 1.5 | med |
| origin server + limits + redacting logger | 3 | med |
| share/ + link codec + landing page | 4 | med |
| cloudflared provider (+ installer, supervisor) | 4 | low-med (Windows behaviour unverified) |
| FakeTunnelProvider | 2 | high |
| receiver connection + resume | 3 | med |
| app + CLI UX, deep links | 3 | med |
| tests, Docker `inet_net`, live run | 4 | low-med |
| orchestrator (seams, protocol, close-out) | 3 | med |
| **Total** | **about 27** | low-med (design said 22; the extra is orchestrator work and the missing AES-GCM primitive) |

## 7. Risks and unknowns

| Risk | Mitigation |
|---|---|
| Cloudflare changes terms or rate limits, or makes the email gate mandatory; large-file clause unclear | Consent screen, small-file bias, FakeTunnelProvider in CI, tiers D / E (zrok, manual URL), S5-C re-check at the start, recorded live test |
| Port 7844 blocked or `trycloudflare.com` filtered on campus networks | HTTP/2 retry, manual URL provider, later 5b direct tiers |
| Pure-Dart AES-GCM too slow (S5-A) | worker isolate per connection, native only in the app layer, bench gate (`tools/bench/gate.sh`) |
| Link leakage through chat apps | UX warning, claim binding, optional approval code, default expiry 1 h |
| Antivirus flags cloudflared on Windows | pinned hash, docs, optional bundling |
| Sender sleeps or goes offline mid-transfer | UX line, sleep inhibitor, resume via new link with same `k` |
| Windows has never been compiled | everything in Inc 5 core is Dart and testable on Linux; Windows live run only after the Windows route exists |
| `HttpClient` reuse accepts any certificate (finding F13) | tunnel client is a separate `HttpClient` with default validation; test that a self-signed host is refused |
| Nonce/AAD mistakes | RFC/NIST vectors, hostile-provider tests, second tester on `tunnel_crypto`, mutations on every guard |

## 8. Free-tooling check

Cloudflare Quick Tunnel (no account, `cloudflared` Apache-2.0) and zrok free tier (OpenZiti, Apache-2.0, 5 GB/day, free token) per design 04 section 1.1, fetched 2026-11-03. **UNVERIFIED today**: limits and terms change often; S5-C re-fetches both pages before any code. GitHub Pages for the landing page: limits per `post-mvp-plan.md` Wave 4; whether Pages is free for the chosen repo type is **UNVERIFIED** and depends on the user's repository decision (post-mvp D1). Everything in the default test run uses the fake provider and costs nothing.

## 9. Criteria for declaring Inc 5 done (all by real exit codes; alone; `flock -o /tmp/libreshare-heavy.lock`)

1. `dart analyze --fatal-infos` and `dart format --output=none --set-exit-if-changed .` rc 0; `grep -RnE "package:flutter|dart:ui" packages/libreshare_core/lib` rc 1.
2. Core, CLI and app suites green, counts >= the Inc 4 closing counts plus the new tests; every new test file 3x green; no existing test changed.
3. FR-14 integration test and Docker step `m)` green with both local nets cut; NFR-04 capture test green; NFR-06 test green; token 401 / 410 tests green; hostile-provider, SSRF and log-hygiene tests green.
4. Mutation table for `tunnel_crypto`, origin limits, link validation, claim binding: every guard removed turns its test red (checked by me in a scratch clone).
5. `docs/test-reports/inc5-live.md` holds one recorded Quick Tunnel transfer (`LS_TUNNEL_LIVE=1`, 20 MiB, Dart client both ends, `cmp` identical, argv without `--allowed-mail`) with date, network description and rc. If the user cannot run it, Inc 5 is **"done except live"** and says so.
6. Loopback throughput not worse than 80 % of the Inc 4 closing figure (bench gate); the extra cost of the tunnel path is reported as a number.
7. LSP-1.md, schemas, conformance vectors, traceability and the user guide updated; `STATUS.md` flag `INC5_DONE: YES`.

## 10. Out-of-scope findings this increment touches
`inc3.md` section 12 leftovers (mitm test, dead code at `libreshare_engine.dart:921`), the PIN-guard counters across restarts, and the Module F cards that touch pairing and the Android service are separate and are not part of Inc 5.

## 11. Questions for the user (only genuine decisions; nothing here blocks the work before Inc 4 is done)
1. **Default internet path.** Ship Cloudflare Quick Tunnel as the default despite "testing and development", no uptime guarantee and an unclear large-file clause, with a first-use consent screen and instant fallbacks? Alternative: zrok first (needs a free account token), or manual URL only.
2. **cloudflared: download or bundle?** Download on first use with a pinned hash (small installers, needs network at first use) vs bundling in the Windows installer / AppImage (+40-55 MB, offline-ready).
3. **Recipient without the app.** Is "the recipient needs no install" required for v1? If yes, the browser receiver (Inc 5c) moves into this increment and a landing-page domain must be reserved first. Recommended: no, the landing page explains how to install.
4. **Android as sender of links.** Accept "Android receives links and sends only on the local network" for this increment (recommended), or invest in an experimental cloudflared-on-Android path?
5. **Repository and landing page.** The landing page needs a public GitHub repo (or another free static host). This ties to the Windows-route question already open (post-mvp D1).

## 12. Outcome / deviations
(To be filled by the orchestrator at close-out. Empty on purpose.)

## 13. Refinement for execution (2026-11-06 14:38:13 by `date`, orchestrator)
- **Order (user decision):** Increment 4 first (`MODULE_I_PROMPT.md`), then Increment 5. Inc 5 starts when STATUS.md says `INC4_DONE: YES`. The earlier "groundwork now" authorization (`MODULE_H_PROMPT.md`: spikes S5-A..E + the three pure modules in `inc5-seams.md`) is therefore QUEUED as the first block of Inc 5, not run in parallel with Inc 4 (machine capacity: one heavy lock).
- **Defaults for Q1-Q5** (flagged, the user may overturn them; they exist so the Lead is not blocked): Q1 Cloudflare Quick Tunnel is the default provider behind a first-use consent screen, zrok opt-in; Q2 `cloudflared` is downloaded on first use with a pinned SHA-256; Q3 the recipient needs the app (no browser receiver in this increment); Q4 Android receives links and sends only on the local network; **Q5 (repository and landing page) stays OPEN** and blocks only the landing page, CI and the live test (Wave 4), none of the earlier waves.
- **Waves after the groundwork block:** the orchestrator writes Wave 0 for Inc 5 (`TunnelProvider`/`TunnelHandle`, share model types, LSP-1 + schema + vector changes, CLAUDE.md rule) against the REAL Inc 4 interfaces, then the Lead runs Waves 1b-3 with the same chain and the same apply cycle as module I. A `MODULE_J_PROMPT.md` for those waves will be written from this section when Inc 4 is accepted, so it uses the real interfaces instead of guesses.
- **Network:** spikes S5-B/C/D need read-only network access (DNS/TCP connect, public pages, release metadata; no binary downloads). If the user does not allow it, they are marked UNVERIFIED and the plan continues with the fake provider.

