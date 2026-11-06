# Design 04 - Internet share link/QR and free internet paths (spec Increment 5, hardened)

| | |
|---|---|
| Status | Proposal, docs only (nothing implemented, installed or started). Needs `docs/plans/inc5.md` and `inc5b.md` before code (CLAUDE.md). |
| Date | 2026-11-03. Every `[Sn]` was fetched or queried on this date (Sources at the end). `UNVERIFIED` = no fetched primary source; test before relying on it. |
| Reads | spec s1 table "Internet tunnel providers", s4.5, s5, s6, s7, s9 (screens 8-9), s16; LSP-1 s4.5, s5; ADR 0002; designs 01 (FGS) and 03 (hotspot) |
| Binding | $0 forever, no paid service, no account the maintainers must operate. Linux + Windows first-class, Android best effort. |

## 0. Decisions at a glance

| # | Decision |
|---|---|
| D1 | Runtime preference for a link share (receiver races the offered candidates, staggered 250 ms): **IPv6 direct > IPv4 mapped direct (UPnP/NAT-PMP/PCP) > Cloudflare Quick Tunnel > zrok > manual URL**. Build order is the reverse for reliability: tunnel first (Inc 5), direct tiers second (new **Inc 5b**), extras in **Inc 5c**. |
| D2 | `--allowed-mail` (2 Oct 2026) is **opt-in**; public Quick Tunnels are unchanged [S2][S3]. It only breaks non-interactive clients if the sender passes it. LibreShare never passes it. |
| D3 | A link share is its **own session kind**: sender publishes, receiver pulls. It is not a `POST /sessions` to a known peer (the receiver is unknown and unreachable). Each receiver claim spawns a child `TransferSession` so events/history/FR-11 are reused. |
| D4 | Canonical QR/link = **https landing URL on GitHub Pages**, every secret in the **fragment**. `libreshare://r?...` carries the same fragment for in-app paste/scan and as the landing page's "open in app" target. |
| D5 | Crypto correction: replace deterministic `fileIndex‖chunkIndex` nonces with **random 96-bit nonces under HKDF purpose subkeys**, canonical length-prefixed AAD, key never reused across process lifetimes (s3). The spec leaves the ack nonce undefined, a latent keystream-reuse bug. |
| D6 | Direct tiers use a **separate ephemeral TLS listener** with a per-share self-signed cert pinned by the link. They never expose the 53318 mTLS API. |
| D7 | cloudflared is **desktop-hosted only** (no Android release asset [S4]); download-on-first-use with pinned SHA-256 (bundling is Open question 3). Android = receive links; send links only via direct tiers (best effort). |
| D8 | Browser receiver (WebCrypto) is **post-MVP (Inc 5c)**, JS served from GitHub Pages, never from the tunnel (a tunnel-served script can steal the key). |
| D9 | **Reject** for v1: hole punching, ngrok, Tailscale Funnel, tunnelmole/serveo/localhost.run as built-ins, Cloudflare Workers/R2 relay as a default. |

## 1. Free internet paths, re-verified (Nov 2026)

### 1.1 Providers

| Provider | Verified facts | Verdict |
|---|---|---|
| **Cloudflare Quick Tunnel** | No account. "no uptime guarantee", "up to 200 in-flight requests" then 429, no SSE, "for testing and development" [S1]. cloudflared **2026.10.7** (30 Oct 2026), Apache-2.0, assets linux amd64/arm64/arm/386, windows amd64/386 (.exe, .msi), macOS; **no Android asset** [S4]. Needs outbound 7844 TCP+UDP (QUIC, auto-falls back to HTTP/2) [S34]; `api.trycloudflare.com:443` (secondary [S35]). | **Tier C, primary** |
| **zrok** | v2.0.9 (31 Oct 2026), Apache-2.0, tarballs linux amd64/arm64/armv7, windows amd64 [S11]. Free $0: 5 GB/day, 25 envs, 50 shares, no card to sign up, interstitial until a card is added [S10]. v2 docs name the CLI `zrok2` (`zrok2 enable`, `zrok2 share public`, `--headless`) [S12b]; the spec still says `zrok`. Header `skip_zrok_interstitial` bypasses the page for non-browsers (documented for self-host; hosted-free behaviour UNVERIFIED) [S12]. | **Tier D, backup** (account token = friction) |
| bore | TCP-only forwarder, no TLS of its own, secret used only in the handshake; bore.pub availability in 2026 UNVERIFIED [S17]. TCP pass-through means our pinned-TLS direct origin works unchanged. | Optional provider, Inc 5c |
| localhost.run | SSH `-R`, anonymous basic use, free domains rotate after hours, speed-limited [S16]; a July 2026 third-party library dropped it as "no longer functional" [S19] (secondary). | Reject as built-in |
| serveo | Docs still online; a July 2026 library changelog implies it runs [S19]; limits UNVERIFIED. | Reject |
| Pinggy free | $0, "60 minutes tunnel timeout", random subdomains, "Unlimited Data Transfer", `ssh -p 443 -R0:127.0.0.1:PORT free.pinggy.io` [S14]. TLS ends at Pinggy. | Inc 5c optional `SshTunnelProvider`; else manual |
| tunnelmole | MIT client, AGPL service, free HTTPS URL, limits undocumented [S18]. | Reject |
| Tailscale Funnel | Beta; ports 443/8443/10000 only; "non-configurable bandwidth limits"; needs tailnet + MagicDNS + HTTPS certs; viewers need nothing [S15]. | Reject as built-in; `ManualUrlProvider` covers users who already run it |
| ngrok free | 1 GB/month out, 20k req/month, 3 endpoints, interstitial [S13]. | Reject |
| Workers/R2 relay | Workers Free: 100k req/day, 10 ms CPU, 100 MB request body; R2 free 10 GB-month, free egress [S20]. Would add store-and-forward (offline sender), the one thing tunnels lack. Needs an operator account, one shared quota, anonymous-upload abuse liability. | Reject as default; "team option" only |

### 1.2 Cloudflare Quick Tunnel in detail

- **`--allowed-mail` gate.** Cloudflare: "Email authentication requires an interactive browser session. It does not support non-interactive clients." [S1] It is enabled only by the flag; "Omitting the flag leaves public tunnels unchanged" [S3 via search summary; S2 does not say it explicitly]. So receivers (Dart `HttpClient`, browser JS) are unaffected. Residual risk: Cloudflare later makes it mandatory (UNVERIFIED, no sign of it). Then Tier C dies for apps and the ladder falls to D/A/B/E. The live test asserts the argv never contains `--allowed-mail`.
- **"100 MB body cap" is a request-body limit** (Free/Pro plans) [S6][S20]. LSP tunnel transfers are `GET` responses of one 4 MiB chunk; only the ack `POST` has a body (<1 KiB). Spec s4.5/s7 should not cite the cap as the reason for 4 MiB (the real reasons are resume granularity and memory).
- **Terms risk (medium, unquantified).** Quick Tunnels are "for testing and development" [S1]. Cloudflare's service terms require a paid service "to serve video and other large files via the CDN" [S5]; Cloudflare's own Tunnels FAQ applies that clause to public hostname routes of named tunnels [S5]. Whether it covers `trycloudflare.com` is UNVERIFIED. Mitigations: user-initiated short-lived transfers only, first-use consent screen quoting the above, Tier A/B/D alternatives, `ManualUrlProvider`.
- **Receiver-side blocking.** Security tooling treats `trycloudflare.com` as a tunnelling/C2 indicator (Sigma/Elastic rules) [S33]; campus or corporate resolvers may block it. Receivers behind such filters need another tier or the browser-free path.
- **Sender egress.** Port 7844 TCP/UDP blocked => no tunnel [S34]. cloudflared retries QUIC with back-off (2..64 s) before HTTP/2, which can exceed our 45 s budget. Strategy: attempt 1 `--protocol auto` (25 s), then kill and retry `--protocol http2` (20 s).
- **Non-browser challenge.** Cloudflare could serve bot challenges to non-browser clients on tunnel hostnames (UNVERIFIED). The live test MUST use the Dart client, not curl.
- **URL discovery.** Parse `https://[a-z0-9-]+\.trycloudflare\.com` from stderr (spec). Cross-check via `--metrics 127.0.0.1:<port>` `/metrics` `userHostname` label (from a 2021 cloudflared commit [S36]; current behaviour UNVERIFIED). Readiness = public `GET /t/<token>/healthz` = 204 from the sender's own resolver, then the receiver retries NXDOMAIN with back-off up to 60 s (negative DNS caching).
- **Pinned-hash strategy.** `tunnel/cloudflared_versions.dart` holds `{version, platform, url, sha256, size}` for `linux-amd64`, `linux-arm64`, `windows-amd64`. The GitHub API now returns a per-asset `digest` (verified in [S4]), so a dev tool `tools/update_cloudflared_pins.dart` regenerates the file and a human reviews the PR. Runtime: download over TLS from the release URL to a temp file, verify SHA-256 and size, `chmod 0700` / ACL user-only, atomic rename to `<appSupport>/bin/cloudflared-<ver>[.exe]`, **re-verify before every launch** (local tamper). Keep current + previous pin (Cloudflare supports one year of releases, spec s7). Apache-2.0 needs the LICENSE/NOTICE shipped in About. cloudflared publishes no detached signature that I found (UNVERIFIED); Windows build is reportedly Authenticode-signed (secondary [S33b]), check in the live test and log, do not hard-require.

### 1.3 Free direct paths (no relay)

**IPv6 global addresses.** Google IPv6 share passed 50% (50.10% on 28 Mar 2026), India 72% [S25]. A global address is not a reachable address: CPEs may default-deny inbound (RFC 6092 profile allows it) [S35b]. Pinholes: UPnP IGDv2 (2010) added IPv6 [S23] (action `WANIPv6FirewallControl:AddPinhole`, from the IGD:2 spec, UNVERIFIED here); PCP supports IPv6 firewall control where "the mapping is the identity function" [S22]. CPE support is uneven (Wikipedia reports Fritz!Box IGDv2/PCP "very buggy") [S23]; success rate UNVERIFIED. The receiver also needs IPv6 (about half of users). Cost: candidate enumeration is trivial (`NetworkInterface.list`, keep `2000::/3`, drop ULA/link-local, advertise at most 2 because Dart cannot tell temporary from stable addresses); pinhole via PCP/UPnP is medium. Listener: `HttpServer.bindSecure(InternetAddress.anyIPv6, port, v6Only: false)` is dual-stack.

**UPnP-IGD / NAT-PMP / PCP (IPv4 port mapping).**
- *Pure-Dart feasibility: yes.* SSDP `M-SEARCH` over `RawDatagramSocket` to 239.255.255.250:1900; device XML + SOAP (`GetExternalIPAddress`, `AddPortMapping`/`AddAnyPortMapping`, `DeletePortMapping`) over `HttpClient` + `package:xml`; NAT-PMP (RFC 6886) and PCP (RFC 6887 [S22]) are small UDP/5351 packets. Existing packages: `port_forwarder` 1.0.0 (MIT, UPnP+NAT-PMP+PCP, unverified uploader, ~18 months old) and `upnp_client` 1.5.0 (verified publisher, IGD) [S21]. Recommendation: own ~500-line implementation under `nat/` with the hardening below; use the packages as references only (small trusted surface, no 3rd-party XML/SOAP quirks hidden).
- *Gateway address:* NAT-PMP/PCP need it; Dart has no API. Linux `/proc/net/route`; Windows parse `route print -4`; Android platform channel (`network_info_plus` gateway support UNVERIFIED). UPnP needs only SSDP.
- *Success rates:* no reliable public figure found (UNVERIFIED). Constraints are known: CGN on 17-18% of eyeball ASes and >90% of cellular ASes (2016 study, stale) [S26]; IGD interop bugs [S23]; ISP/campus/enterprise routers often disable UPnP; phone hotspots never map. Treat as opportunistic.
- *Security risks and mitigations:*

| Risk | Mitigation |
|---|---|
| Exposing the API to the Internet | Map only a **dedicated origin port** (53330-53349, s4); TLS-only, per-share ephemeral cert pinned via link, token + AEAD, zero unauthenticated routes (everything else = same 404), handshake/IP rate limits. 53318 mTLS API is never mapped. |
| Stale or permanent mappings | Lease 3600 s, renew at 50%; `DeletePortMapping` on stop and on every exit path; description `LibreShare:<deviceId>`; persist mapping ids in D2 and `sweepStale()` at startup. Error 725 (permanent only): accept only if the delete is persisted. |
| Hostile LAN device answers SSDP / redirects SOAP | Accept `LOCATION` only if host == SSDP source IP and it is RFC1918/ULA/link-local; no redirects; 3 s timeouts; XML <= 64 KiB, no DTD/entities. |
| Mapping for another host (UPnProxy-style abuse) | `NewInternalClient` = our own address only; never PCP `THIRD_PARTY` [S22]. |
| CallStranger class (SUBSCRIBE callback SSRF, CVE-2020-12695) [S24] | We never subscribe to UPnP events and never run a UPnP device. |
| Port scanners | Random port in the reserved range, listener alive only while a share is active, closed on revoke/expiry. |
| IP disclosure | A direct candidate reveals the sender's public IP to the link holder: one-line disclosure in the Create-link sheet and a "Hide my IP address" toggle (forces tunnel-only). |
| Host firewall | Windows: installer rule widened to 53318-53349 (spec s15 says 53318-53327); Fedora Workstation opens 1025-65535 by default [S31]; ufw/other: document `ufw allow 53330:53349/tcp`. |

- *Reachability check:* a sender cannot truly self-test without an outside party. `ReachabilityProbe` reports **possible**, not reachable: (i) IGD/PCP external IP must be public (not RFC1918, not 100.64.0.0/10); (ii) optional STUN reflexive IPv4 must equal it (else double NAT); (iii) optional hairpin connect; (iv) the final truth is the receiver's race.

**STUN-assisted hole punching: reject for v1.** The product is HTTP over TCP. Punching needs (a) a signalling rendezvous the sender does not have, and (b) a UDP transport (a pure-Dart `quic_lib` exists, maturity UNVERIFIED [S28]) or fragile TCP simultaneous open. The best public measurement (libp2p DCUtR, IMC '26) reports **70% +/- 7.1%** success, TCP and QUIC alike, and only after relay-based signalling [S27]. Possible later spike: use the tunnel as the signalling channel. STUN stays useful only as a tiny client (about 80 lines) for learning the external IPv4 when the user forwarded a port by hand (`stun.l.google.com:19302`, free, "no guarantee" [S37]; `stun.cloudflare.com` UNVERIFIED).

### 1.4 Ranked ladder, "sender behind NAT, receiver anywhere"

| Rank | Tier | Works when | Fails when | Reliability | Effort | Build |
|---|---|---|---|---|---|---|
| 1 | A: IPv6 direct | both ends have global IPv6 and CPE allows inbound or grants a pinhole | CPE default-deny without PCP/IGDv2, v4-only receiver | low-medium, UNVERIFIED | candidates: 0.5 d; pinhole: 3 d | 5b (candidates), 5c (pinhole) |
| 2 | B: IPv4 mapped | home router with UPnP/NAT-PMP/PCP on, public WAN IP | CGN, cellular, campus, UPnP off | medium at home, ~0 on mobile | 8 d incl. tests | 5b |
| 3 | C: Cloudflare Quick Tunnel | sender reaches Cloudflare on 7844, receiver can resolve/reach trycloudflare.com | 7844 blocked, domain filtered, ToS/gate change | **high** (only near-universal tier) | 9 d | **5** |
| 4 | D: zrok public share | user pasted a free account token; <= 5 GB/day | no token, quota, interstitial for browsers | medium | 3 d | 5 (last) |
| 5 | E: manual URL | user supplies any https URL reaching the origin (own VPS, Funnel, forwarded port, SSH tunnel) | needs expertise | user-dependent | 0.5 d | 5 |

Why this order. Runtime: direct paths are faster, keep working if a provider changes terms, and need no binary; the receiver races them so a dead tier costs <= 3 s. Build: C is the only tier that works for most (sender, receiver) pairs today, and its machinery (origin server, crypto, link, receive flow) is exactly what A/B reuse, so C first. A/B follow in 5b; their value is resilience and speed. Implement D inside Inc 5 only after C passes its live test; E is nearly free.

### 1.5 Data-volume realities

| Constraint | Consequence |
|---|---|
| 4 MiB `GET` per chunk, 4 in flight | 16 MiB buffered; response bodies, so the 100 MB request cap is irrelevant; ack `POST` < 1 KiB. |
| 200 in-flight cap per tunnel, 429 beyond [S1] | A token holder can hold slots. The origin enforces <= 8 concurrent per token and <= 32 total, write timeout 60 s per chunk, so a hostile client cannot reach 200 and starve the real receiver. |
| No SSE | Sender progress comes from sealed ack `POST`s; receiver progress is local. |
| Sender uplink is the bottleneck | 1 GB takes 13.3 / 2.7 / 1.3 min at 10 / 50 / 100 Mbit/s; 10 GB ten times that. Sender must stay online and awake. |
| No documented Quick Tunnel quota | zrok: 5 GB/day [S10]; browsers receiving > ~1 GB fall back to the app (s2.7). |
| Pure-Dart AES-256-GCM speed | UNVERIFIED; benchmark in Inc 5 (isolate per connection). Needs >= 15 MB/s to saturate 100 Mbit/s. |

## 2. Link format and flow

### 2.1 Format

```
https://libreshare.github.io/r#v=1&h=quiet-lamp-demo-wolf.trycloudflare.com&t=ABkLScJAffjjp9vnJ60X5w
  &k=9XGqai5pBy8t4HsHIxcu68X4_e4fOg7MYyKYMHc7WPA&m=1&e=1793612400&n=Ravi-ThinkPad&fp=9F2C41D0AA7B33E1
  &d=[2001:db8:1:2::7]:53331&d=203.0.113.9:53331&pin=<32 hex>        (d/pin only when direct tiers are offered)
libreshare://r?<identical fragment parameters>
```

| Param | Meaning |
|---|---|
| `v` | link version (1) |
| `h` | tunnel hostname (DNS name only, https, port 443) |
| `t` | 128-bit token, b64url (path component `/t/<t>/...`) |
| `k` | 256-bit root key, b64url. `shareId` and `sessionId` are **derived** from it (s3.2), so the spec's `s=` is dropped |
| `m` | max receivers (1 default; 0 = anyone) |
| `e` | expiry hint (unix s); real expiry is enforced by the sender |
| `d` | direct candidate `ip:port`, repeatable; public unicast addresses only |
| `pin` | first 32 hex of SHA-256(DER) of the ephemeral origin cert (128 bit; the spec's 16-hex `fp` is too short to pin a TLS key) |
| `fp`, `n` | sender identity fingerprint prefix and alias: **display hints**, authenticated only by the signature in the sealed manifest (s3.4) |

Size: tunnel-only link about 170 chars (QR v8, error correction L, byte mode capacity 192); with two direct candidates about 280 chars (QR v11, capacity 321). Receivers MUST: cap input at 2 KiB; ignore unknown params; require `h` to be a DNS name (no IP literal, no userinfo, port 443) and `d` to be global unicast (reject loopback, RFC1918, ULA, link-local, 100.64/10) unless a developer flag is set. Otherwise a crafted link makes the receiver probe its own LAN (SSRF). Content stays authenticated by AEAD either way. Stock phone cameras open https QRs but not unknown schemes, hence https is canonical.

### 2.2 Sender UX: "Create link"

1. Entry points: Send screen third option "Share via link (anyone, anywhere)"; Home "My QR" menu; CLI `ls link <files...> [--expires 1h] [--receivers 1] [--provider cloudflare|zrok|manual:URL|fake] [--no-direct]`.
2. Sheet: *Expires* 15 min / 1 h (default) / 24 h; *Receivers* 1 (default) / up to 5 / anyone; *Connection* Automatic or "Hide my IP address". One disclosure line: "Direct connections show your IP address to whoever opens the link."
3. Prepare: hash files (progress; all hashes are known before sharing, which also fixes the >2 GiB `sha256:null` gap), start origin, start tunnel (spinner, up to 45 s; two attempts s1.2), map ports if 5b.
4. Link ready: QR, Copy, OS Share (Android/Windows share sheet), expiry countdown, **"Keep LibreShare open and this computer awake until the download finishes"** (sleep inhibitor on while a share is live), per-receiver rows (Waiting / Approve? / 42% 3.1 MB/s / Done), **Stop sharing**.
5. Warn once: "Anyone who sees the full link can download the files. Do not paste it into chat apps that scan messages (Slack, Telegram cloud chats, email scanners)."

### 2.3 Receiver flow ("Receive from link", screen 9)

Paste / scan / OS deep link -> parse + validate -> race candidates (A,B at t=0 and +250 ms, C at +500 ms, E last; 3 s connect each; first healthy wins, losers cancelled) -> `GET manifest` -> decrypt -> confirmation card: alias, `fp`, count, total size, "Verified contact" badge only if the manifest signature matches a trusted device (s3.4), expiry -> Download -> 4 chunks in flight -> verify whole-file SHA-256 -> atomic rename (existing sanitizer applies) -> sealed final ack -> done. Installed apps register `libreshare://` (Windows HKCU class written by the app like the Run key in design 01 D5; Linux `x-scheme-handler/libreshare` in the `.desktop`; Android intent filter) via `app_links` (7.2.2, Apache-2.0; Windows/Linux docs not summarised on pub.dev, verify) [S38] with a single-instance forwarder on desktop.

### 2.4 Modes, expiry, revocation

| Item | Rule |
|---|---|
| Lifetime | `expires = min(created + chosen, 24 h)`; idle 30 min after the first claim; Quick Tunnel dies when the app exits, which kills the link too. |
| Receivers | `m=1`: the **first claimant binds the share** (random 128-bit `X-LS-Claim` on every request, persisted by the receiver); other claimants get 409 until the sender approves a second one. `m=N`: up to N claims, each approved or auto per setting. `m=0`: anyone, rate-limited, still capped by the byte budget below. |
| Consumption | One-time means **one authenticated completion** (sealed final ack), never "N raw GETs": a token holder without the key must not burn the single use. |
| Approval option | "Ask me": the sender sees `SAS = HKDF(k, claim)` as 6 digits next to the receiver's identical code; the sender taps Allow only if the numbers match (tells a link thief from the intended person). |
| Revocation | Stop sharing, expiry, final ack in one-time mode or app exit: token zeroed, in-flight responses aborted, origin answers 410 for that token, mapping removed, tunnel closed when no live share remains. |
| Byte budget | Per share: 2 x total size x allowed receivers of served bytes (retransmits counted); exceed => revoke + notify. Optional upload-rate cap (NFR-08). |

### 2.5 Resume and multiple receivers

Receiver state (`.lspart` + D2 bitmap) is keyed by derived `shareId`; reopening the same link, or a new link with the same `k`, resumes with only missing chunks (existing `FileState` semantics, receiver-side). A cloudflared edge reconnect keeps the hostname; a **cloudflared process restart gives a new hostname**, so the old link is dead: the sender re-shows a new link/QR (same `k`, same token, new `h`), the receiver pastes it and resumes. If the receiver is also a known LAN peer the new offer rides the normal session. Auto-rotation without re-sharing needs a signalling beacon (a sealed mailbox keyed by `k`; the relay mechanism proposed in `02-free-rendezvous.md` could carry it): Inc 5c idea, UNVERIFIED. Multiple receivers each get independent chunk state; the sender's origin is stateless apart from claims and the byte budget.

### 2.6 Landing page on GitHub Pages (decision: yes)

| Question | Answer |
|---|---|
| Free and allowed? | Yes: 1 GB site, 100 GB/month soft bandwidth, no commercial SaaS [S29]. Name `libreshare.github.io` (org/repo reservation is Open question 4). `*.github.io` is on the Public Suffix List (cookie isolation; from memory, UNVERIFIED). No custom domain ($0). |
| Why not serve the page from the sender's origin (spec s4.5 style)? | A page delivered through the tunnel is controlled by the tunnel provider; a script there can read `location.hash` and exfiltrate `k`. A static page on a third party keeps provider and code separate. The origin still answers `GET /t/<token>` with a tiny static HTML ("open the full link in LibreShare") so link-preview bots do not trigger anything. |
| Content | (1) "Open in LibreShare" button -> `libreshare://r?<fragment>`; (2) download links to GitHub Releases for Windows/Linux/Android; (3) later the Inc 5c browser downloader. No analytics, no third-party fonts/scripts. |
| Privacy | The fragment is never sent in HTTP requests; GitHub sees only `GET /r` plus IP/UA. `<meta name="referrer" content="no-referrer">` (Pages cannot set response headers, so use meta CSP too); read the fragment, then `history.replaceState` to strip it from the address bar. Browser history/sync may still record the original URL (UNVERIFIED). |
| Failure mode | If github.io is down or blocked, app receivers still work (they parse the link locally). Only browser/not-installed receivers depend on it. |
| Android App Links | Verified links need `/.well-known/assetlinks.json` at the host root, possible only for a root org site; otherwise the OS shows an "Open with" chooser. Acceptable. |

### 2.7 What the receiver needs installed; browser download (NFR-08), optional Inc 5c

| Receiver has | Result |
|---|---|
| LibreShare (Linux, Windows, Android) | Every tier A-E, resume, "Verified contact" badge, any file size. |
| Only a browser, Inc 5 | Landing page explains the app and offers downloads. The origin serves only ciphertext, so a plain `<a download>` of the link **cannot** work: nothing readable is ever served. |
| Only a browser, Inc 5c | Decrypt-in-page, tunnel tiers C/D only, about 1 GB cap, Chromium streams to disk, Firefox/Safari buffer in memory. |

Feasible and E2E if the script comes from GitHub Pages, not the tunnel. Page: parse fragment; `crypto.subtle` (needs a secure context: https is satisfied) does HKDF and AES-GCM; `fetch` the manifest and chunks cross-origin from `https://<h>/t/<t>/...`; origin sends `Access-Control-Allow-Origin: https://libreshare.github.io` (exact), `Vary: Origin`, handles `OPTIONS`; ack via sealed `POST`. Saving: `showSaveFilePicker` is Chromium-only, **Firefox and Safari do not support it** (web.dev, updated 2026-06-26) [S30]; they fall back to an in-memory Blob, so warn and cap the browser path at about 1 GB. WebCrypto has no incremental SHA-256, so the sealed manifest carries per-chunk SHA-256 (1250 x 32 B = 40 KB for 5 GB) and GCM tags give integrity per chunk. Direct tiers do not work in browsers (self-signed cert); tunnel tiers C/D only (zrok free interstitial blocks `fetch` with preflight, UNVERIFIED). Verdict: ship the plain landing page in Inc 5, the downloader in 5c if the user wants "recipient needs nothing installed" (Open question 4).

## 3. Security review of spec s4.5 / s5

### 3.1 Findings

| # | Finding | Severity | Correction |
|---|---|---|---|
| F1 | **Ack/receiver-sealed nonce is undefined.** Receiver seals `{fid,idx}` under the same key as sender chunks. If an implementer reuses `fileIndex‖chunkIndex` the ack and chunk share (key, nonce): keystream XOR leaks the first ~30 plaintext bytes of the chunk (ack text is guessable) and reveals the GHASH key (forgery). | **High** | Purpose subkeys + random nonces (s3.2). |
| F2 | **Deterministic nonce is safe only if plaintext at (file, chunk) never changes under the key.** Retransmit with an unchanged file yields identical ciphertext (no leak). It breaks if the file is edited/appended while shared, if a session resumes after restart with the persisted key (`tunnelOffer` stored in D2) and a different file state, or chunk size changes. | **High** | Random nonce per seal removes the class. Also `stat` size+mtime before each chunk read; mismatch => abort share, `FAILED(PROTOCOL_ERROR)`. New `k` on every process start. |
| F3 | **Manifest nonce `0xFFFFFFFF‖0` is single-use.** Re-sealing an updated manifest (e.g. late `sha256` for >2 GiB files) reuses it. | Medium | Random nonce; but also compute hashes before sharing (s2.2). |
| F4 | **AAD `sessionId‖fileId‖idx` is unspecified and ambiguous** (`"f1"‖"10"` = `"f11"‖"0"`), does not bind purpose/direction/length. | Medium | Canonical AAD below. |
| F5 | **Token in the URL path.** It reaches provider logs, our own `shelf` access logs, link-preview bots, and `Referer` of any page opened from a browser view. Alone it only fetches ciphertext, but a leaked token lets a stranger burn uplink and, in naive one-time logic, consume the single use. | Medium | Never log paths (custom logger redacts `/t/<token>`); `Referrer-Policy: no-referrer`; one-time = authenticated completion (s2.4); cloudflared `--loglevel info` only (debug logs request paths). Extend CLAUDE.md rule "never log URL fragments" to "and tunnel tokens". |
| F6 | **Provider MITM.** Cloudflare terminates TLS: it sees token, sizes, timing, both IPs; it cannot decrypt, but can drop, delay, replay or reorder. AEAD + position-bound AAD + manifest chunk count + whole-file SHA-256 detect tampering; withholding is DoS only. If the provider ever served script (the spec's origin-hosted page), E2E would be void. | Medium (by design) | Document the metadata exposure; never serve decrypting JS from the tunnel (D8). Receiver pins nothing for tunnels (public CA); for direct tiers it pins `pin`. |
| F7 | **Hostile receiver DoS on the sender's uplink** (slow-read, repeated full downloads, 200-slot exhaustion). Spec has per-IP limits only for `POST /sessions`. | Medium | Origin limits: <= 8 concurrent per token / 32 total, 60 s write timeout, per-client limit using `Cf-Connecting-Ip` (trusted: only local processes reach loopback), byte budget (s2.4), revoke on breach. |
| F8 | **Link leakage.** Fragment keeps `k` from HTTP servers, but chat apps with server-side link handling, browser sync and screenshots see it. | Medium | UX warning (s2.2), claim binding + optional approval code (s2.4), short default expiry. A passphrase layer does not help (a 6-digit PIN falls to offline brute force once the attacker holds the link). |
| F9 | **`fp` is unauthenticated** in the link; an attacker copies a victim's `fp` into their own link. | Low-Med | Sealed manifest includes the sender cert + ECDSA signature over `SHA-256("LSP1-LINK" ‖ shareId ‖ manifestDigest)`; "Verified contact" only if it validates against a trusted device. |
| F10 | **Receiver SSRF via crafted link** (private/loopback `h`/`d`). | Medium | Validation rules in s2.1. |
| F11 | **Direct tiers expose a TCP port.** | Medium | Mitigation table in s1.3; pinned ephemeral TLS; no unauthenticated routes. |
| F12 | **Orphaned cloudflared** after an app crash keeps a hostname alive. Harmless (origin gone) but leaks a process. | Low | pidfile + kill-stale at startup. |
| F13 | **Certificate handling.** Tunnel hosts present a public-CA certificate (Cloudflare edge for `*.trycloudflare.com`). The codebase uses `badCertificateCallback` for pinned peers; reusing that `HttpClient` for tunnel hosts would silently accept any certificate. Plain HTTP between cloudflared and the loopback origin is fine (ciphertext only, same host). | Medium | Separate `HttpClient` with default validation for `h`; pinned client only for `d` candidates, comparing SHA-256(DER) to `pin` and checking validity dates. Test: a self-signed server on `h` must be refused. |

### 3.1b Nonce uniqueness analysis

*Spec scheme* (`nonce = u32 fileIndex || u64 chunkIndex`, manifest `0xFFFFFFFF||0`, key per session). The map (fileIndex, chunkIndex) -> nonce is injective, and `fileIndex <= 10,000 < 0xFFFFFFFF` keeps the manifest nonce disjoint from every chunk. A retransmit of position p repeats (key, nonce, AAD) with the **same** plaintext, so it yields byte-identical ciphertext and leaks only "p was resent". Hence uniqueness holds if and only if: (i) the key is fresh per process lifetime, (ii) plaintext(p) is immutable while the key lives, (iii) the manifest is sealed once, (iv) receiver-originated messages use a disjoint nonce space or key. The spec guarantees none of (i)-(iv) (F1-F3), and two of them are violated by ordinary events (a user saves the file again; the app restarts and resumes a 24 h session).

*Proposed scheme.* Independent subkeys per purpose make cross-purpose collisions harmless. Within one subkey, nonces are i.i.d. uniform 96-bit values, so the probability that any two of n seals collide is below n^2 / 2^97 (2^-57 at n = 2^20), and the 2^24 seal cap per `k` keeps it below 2^-49. No state, no persistence, no reliance on file immutability.

### 3.2 Proposed construction (replaces spec s5 "Tunnel E2E" row and LSP-1 s4.5 "Crypto")

```
k        = 32 random bytes per share per process lifetime (never persisted for reuse after restart)
prk      = HKDF-Extract(salt = "LSP1-TUN-v1", ikm = k)
shareId  = HKDF-Expand(prk, "sid", 16)          // sessionId (UUID form) and resume key
kMan     = HKDF-Expand(prk, "manifest", 32)     // sender -> receiver, sealed once per request
kData    = HKDF-Expand(prk, "data", 32)         // sender -> receiver chunks
kAck     = HKDF-Expand(prk, "ack", 32)          // receiver -> sender
nonce    = 12 bytes from Random.secure(), sent in band: nonce || ciphertext || tag(16)
AAD      = "LSP1" || purpose(1) || shareId(16) || u32 fileIndex || u64 chunkIndex || u64 plaintextLen
           purpose: 1 manifest, 2 chunk, 3 ack; manifest uses fileIndex=0xFFFFFFFF, chunkIndex=0
claim    = X-LS-Claim: 16 random bytes; SAS = u32(HKDF-Expand(prk, "sas" || claim, 4)) mod 10^6
```

- Random 96-bit nonces under each subkey: with n seals the collision probability is about n^2 / 2^97 (2^-57 at n = 2^20; NIST SP 800-38D budget is 2^32 per key). Hard cap 2^24 seals per `k`, then the share ends. Retransmits, multi-receiver serving, late manifest changes and file edits can no longer cause reuse.
- Use of the existing `cryptography` `AesGcm.with256bits()` with explicit nonce and AAD; add `HKDF` from the same package. Test vectors: NIST/RFC 5869; cross-checked with the Inc 5c JavaScript implementation via a shared JSON vector file.
- Chunk integrity also needs no `X-LS-Chunk-SHA256` on tunnel responses (GCM tag per chunk); whole-file SHA-256 stays (sealed manifest, plus sealed `/f/{fid}/hash` if a late hash is ever needed).

### 3.3 Spec / LSP-1 corrections (concrete)

1. s5 table row "Tunnel E2E" and LSP-1 s4.5 "Crypto": replace by s3.2 (subkeys, random nonce, canonical AAD, AAD purposes, key lifetime).
2. s4.5 / LSP-1 s4.5 "Link": new format (s2.1): landing-URL base, derived `shareId` (drop `s=`), `pin` 32 hex for direct, `m`, `e`, `d`; `fp` is a hint only.
3. s4.5 route table: add `GET /t/{token}` (static HTML, no side effect), `OPTIONS` handling when the browser path ships, `X-LS-Claim` header, 410 after revoke, `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `Content-Type: application/octet-stream`, and the origin limits of F7. Note that ack/final-ack plaintext carries `{fid,idx}` / `{final,verified}`.
4. s1 table and s7 item 2: "100 MB body cap" is a **request-body** limit; remove it as a design rationale. `--allowed-mail` is opt-in: change the "Verdict" text to "never pass it".
5. s7 item 3: zrok CLI is `zrok2` in v2 docs; confirm the binary name inside `zrok_2.0.9_*` tarballs before coding. Add: free-tier public shares show an interstitial to browsers [S10]; app receivers send `skip_zrok_interstitial` (verify live).
6. s7 item 4: Android hosting stays out (verified: no Android asset, DNS `[::1]:53` problem on Linux builds [S7], exec from app-data blocked for targetSdk >= 29 [S9]). Android can host **direct** shares in 5b.
7. s6 ladder: add **Tier 3a DirectConnection** (IPv6 / mapped IPv4) beside `TunnelConnection`, both thin subclasses of `OriginPullConnection(baseUrl, trust)`; they differ only in URL and TLS trust (system roots vs pinned cert). NFR-06 still holds (links are used only when no local tier exists).
8. s6 pre-warming: tunnels for known-peer sessions are still pre-warmed; for link shares the tunnel starts on "Create link" only (each creation consumes Cloudflare rate budget; back off 10 s/30 s on 429/1015 as in s7).
9. s15 Windows firewall rule `localport=53318-53327` -> `53318-53349` (direct-origin range 53330-53349).
10. s9 screen 9: confirmation card shows alias + fp + "Verified contact" and the expiry; screen 8 gains a "Link QR" variant. s16 risks: add "Quick Tunnel terms/gate/ToS change", "port 7844 blocked", "receiver-side domain blocklists", "UPnP security", "sender must stay online".
11. CLAUDE.md rule: "Never log ... tunnel URL fragments" -> "... tunnel URL fragments or tokens".
12. LSP-1 s0.1 `tunnelOffer` schema: add optional `candidates` (`d` list) and `pin`, `m`; `keyB64` stays inside mTLS for known-peer sessions.

## 4. Hosting details

| Topic | Desktop (Linux x64/arm64, Windows x64) | Android |
|---|---|---|
| Tunnel host | Yes (cloudflared asset exists for all three [S4]; Windows ARM64 runs the amd64 build under emulation, UNVERIFIED) | **No in MVP.** No release asset [S4]; Linux builds fail DNS (`[::1]:53`), only `termux-chroot` or GOOS=android builds worked [S7]; executables in app data are blocked for targetSdk >= 29, the Termux workaround is shipping in `jniLibs` [S9]; a Flutter plugin `cloudflared_tunnel` 1.0.1 (unverified uploader, 54 downloads, 9 months old) proves feasibility via gomobile but is not a dependency candidate [S8]. |
| Direct host | Yes | Best effort in 5b: pure Dart works on Wi-Fi (IPv6, UPnP); never on cellular CGN; needs a foreground service for the share's lifetime (type per design 01 D6) and `MulticastLock`. |
| Receive link | Yes | Yes (`HttpClient`, system trust store). |

- **Process lifecycle.** `ProcessSupervisor` owns start, ready detection, restart-once (new hostname => `TunnelLost`), `SIGTERM` then `SIGKILL` after 3 s (Windows: `kill()`), pidfile `<appSupport>/run/tunnel.pid` and kill-stale at startup. Never persist raw stderr; scrub through the log parser (only the hostname is kept in memory). Mark child stdout/stderr as drained so pipes never block.
- **Clean config.** Quick tunnels may not work when `~/.cloudflared/config.yaml|yml` exists [S39]. Start with a temp dir as `HOME` (Linux) and `USERPROFILE`/`APPDATA`/`LOCALAPPDATA` (Windows) while keeping `SystemRoot`/`PATH`/`TEMP` (do not use `includeParentEnvironment: false` on Windows). `/etc/cloudflared/config.yml` is not covered by that trick: also pass `--config <empty file in the temp dir>` (effect UNVERIFIED; add to the live test), and `--no-autoupdate`.
- **Windows.** A GUI-subsystem parent spawning a console child can flash a console window; the Dart SDK handles `CREATE_NO_WINDOW` when stdio is piped [S32] (ensure piped stdio, test on Windows 11). Binary is 55 MB. Mark-of-the-Web is not set by `dart:io` downloads, but Defender may scan the new exe; I found no report of cloudflared being flagged malicious (one secondary scan page: 1 of 74 engines, July 2026, unverified [S33b]); managed machines may alert on cloudflared execution from AppData (Elastic/Sigma rules) [S33]. Mitigate: pinned hash, doc for exclusions, optional bundling in the installer (Open question 3).
- **Linux.** AppImage is read-only: install the helper in `$XDG_DATA_HOME/libreshare/bin` (`noexec` /tmp avoided). Fedora Workstation firewalld opens 1025+ [S31], Ubuntu ufw is off by default (document rules).
- **Direct-origin firewall.** Loopback tunnel origin needs no inbound rule. Direct origin: s1.3 table.

## 5. Module plan, tests, increments

### 5.1 Files (additions to spec s3; `packages/libreshare_core/lib/src/` unless noted)

| Area | Files |
|---|---|
| `tunnel/` | `tunnel_provider.dart` (interfaces), `cloudflared_provider.dart`, `cloudflared_versions.dart`, `binary_installer.dart`, `process_supervisor.dart`, `zrok_provider.dart`, `manual_url_provider.dart`, `fake_tunnel_provider.dart`; 5c: `bore_provider.dart`, `ssh_tunnel_provider.dart` |
| `share/` (new module) | `link_share.dart` (state machine, modes, claims, byte budget), `share_link.dart` (+codec, validation), `share_store.dart` (D2 extension) |
| `server/` | `tunnel_origin_server.dart` (routes, limits, redacting logger, loopback + optional TLS listener) |
| `security/` | `tunnel_crypto.dart` (HKDF, AEAD, AAD, SAS), reuse `cert_factory.dart` for ephemeral cert |
| `connection/` | `origin_pull_connection.dart` (client: manifest, chunks, ack, resume), `tunnel_connection.dart`, `direct_connection.dart`, `candidate_race.dart` |
| `nat/` (5b) | `ip_classify.dart`, `ssdp.dart`, `upnp_igd.dart`, `nat_pmp.dart`, `pcp.dart`, `gateway_discovery.dart`, `stun_client.dart`, `port_mapper.dart`, `reachability_probe.dart` |
| app / platform | `platform/{deep_link_handler,sleep_inhibitor}.dart`, screens 8-9 changes; `site/` (static landing: `index.html`, `r/index.html`, later `receive.js`) deployed by an Actions workflow |

### 5.2 Interface sketches

```dart
abstract interface class TunnelProvider {
  String get id;                                   // 'cloudflare-quick' | 'zrok' | 'manual-url' | 'fake'
  Future<bool> isAvailable();                      // pinned binary present / token set
  Future<TunnelHandle> open(int localPort, {Duration ready = const Duration(seconds: 45)});
}
abstract interface class TunnelHandle {
  Uri get publicBase;                              // https://host, no path, no token
  Stream<TunnelEvent> get events;                  // Up | Lost(reason) | RateLimited(retryAfter) | Log(scrubbed)
  Future<void> close();
}
abstract interface class PortMapper {
  Future<GatewayInfo?> discover({Duration timeout});          // kind: upnpIgd1|upnpIgd2|natPmp|pcp, externalIp, cgnat?
  Future<PortMapping> map(int internalPort, {Duration lease = const Duration(hours: 1), String tag});
  Future<void> unmap(PortMapping m);
  Future<int> sweepStale();                                   // removes LibreShare:<deviceId> leftovers
}
abstract interface class ReachabilityProbe {
  Future<ReachabilityReport> assess();             // v6 globals, v4 external, cgnat flag, per-candidate confidence (possible|unlikely)
}
final class OriginCandidate { OriginKind kind; Uri base; String? tlsPinHex; }   // tunnel | ipv6 | ipv4Mapped | manual
```

`TransferSession`, `ConnectionManager` and `FileState` are untouched; `LinkShare` produces `OriginCandidate`s, `candidate_race.dart` implements the staggered race, and `OriginPullConnection` satisfies the existing `Connection` contract for the receiver.

### 5.3 Headless test plan

| Layer | Tests |
|---|---|
| Unit | `tunnel_crypto_test` (RFC 5869 and NIST GCM vectors; tamper, wrong AAD, swapped chunk, wrong purpose; 100k seals no repeated nonce; ack cannot decrypt as chunk), `share_link_test` (round trip, size, validation/SSRF rejects, unknown params), `link_share_test` (modes, claim binding, one-time = authenticated completion, expiry with fake `Clock`, byte budget), `origin_limits_test`, `redacting_logger_test` (no token/fragment ever in output), `cloudflared_log_parser_test` (recorded real stderr fixtures incl. rate-limit and "Unregistered tunnel connection"), `cloudflared_versions_test` (pins well-formed, tampered file rejected, re-verify on launch), `process_supervisor_test` (scripted fake child: ready, crash, hang, double-kill, stale pidfile) |
| `FakeTunnelProvider` | In-process reverse proxy on 127.0.0.1 to the origin that behaves like the provider: 429 above 200 in flight, 100 MB request-body cap, `Host`/`Cf-Connecting-Ip` injection, latency/loss knobs, **capture buffer** (for `e2e_ciphertext_test`: plaintext pattern never appears) and **hostile mode** (flip bits, swap/replay/drop chunks, replay old acks) |
| Integration (one process) | Two engines + `FakeTunnelProvider` + `FaultyTcpProxy`: multi-file link share byte-identical; kill receiver mid-way and resume from the bitmap with a new link and same `k`; token 401/410 after COMPLETED/expiry/revoke; second claimant refused; hostile provider => `FAILED(VERIFY_FAILED)` or clean retry; DoS: 300 slow clients cannot starve one real client |
| Docker e2e | Compose network `inet_net` plus the Inc 4 nets: sender and receiver with both local nets cut transfer via the fake tunnel (FR-14). 5b: `gateway` container (iptables MASQUERADE + a UPnP daemon such as miniupnpd, packaging in the chosen base image UNVERIFIED) between `lan_net` and `inet_net`: sender maps via real UPnP, receiver in `inet_net` pulls via `DirectConnection` with the pinned cert; wrong `pin` refused. Needs `NET_ADMIN` (already required by `netem`) |
| NAT fakes (5b) | `FakeIgdGateway` (loopback HTTP device XML + SOAP, SSDP responder with an injected unicast search target), cases: success, 718 conflict -> next port, 725 permanent-only, 606/501 errors, hostile `LOCATION` (public IP, other host, redirect, oversize XML, DTD), slow gateway; `FakePcpServer`/NAT-PMP (UDP loopback, result codes, version fallback); `FakeStunServer`; stale-mapping sweep after simulated crash |
| Live (manual, gated) | `LS_TUNNEL_LIVE=1`: download + verify pinned cloudflared, open tunnel, `healthz`, 20 MiB through the **Dart client**, kill => `TunnelLost`, argv has no `--allowed-mail`, log HTTP/2 fallback with 7844/UDP blocked; Windows 11 run (console flash, Defender, `Get-AuthenticodeSignature`). `LS_ZROK_TOKEN` additionally for zrok. `LS_NAT_LIVE=1` on a real router (record vendor, UPnP/PCP/IPv6 pinhole result). Reports in `docs/test-reports/` (phone hotspot receiver vs campus Wi-Fi sender, spec Inc 5) |

### 5.4 Increments

| Inc | Scope | Acceptance (adds to spec) |
|---|---|---|
| **5** (tightened) | `tunnel_crypto` v2, origin server + limits, `share/`, link codec + landing page (static), `OriginPullConnection`/`TunnelConnection`, `CloudflaredProvider` (+installer, supervisor), `FakeTunnelProvider`, `ManualUrlProvider`, `ZrokProvider` last, Create link + Receive from link (app + CLI `link`/`receive-link`), deep links. Android FGS timeout handling moves per design 01. | FR-14 as spec; NFR-04 ciphertext-only capture **and** hostile-provider tests; NFR-06; token/claim/expiry tests; one recorded live Quick Tunnel transfer with the Dart client |
| **5b** (new) | `nat/` (IPv6 candidates, SSDP/IGD, NAT-PMP, PCP, STUN client, reachability), ephemeral-TLS direct origin, `DirectConnection`, candidate race, `d`/`pin` in links, disclosure + "Hide my IP", installer firewall range, Docker gateway e2e | Direct transfer through fake IGD in-process and through the Docker gateway; wrong pin refused; no mapping left after stop/crash-sweep; mapping never targets another host |
| **5c** (stretch) | WebCrypto landing downloader (<= ~1 GB), IPv6 pinhole (IGDv2/PCP), `BoreProvider`, `SshTunnelProvider`, URL-rotation beacon, Android tunnel-host experiment | per item; cross-implementation vectors Dart vs JS |

Rough effort (person-days): Inc 5 about 22 (crypto 1, origin 3, link/UX 4, cloudflared 4, fake provider 2, landing 1, receiver 3, tests/live 4); 5b about 14; 5c about 15.

### 5.5 Risks

| Risk | Likelihood / impact | Mitigation |
|---|---|---|
| Cloudflare changes terms, rate-limits, makes the gate mandatory, or flags large-file use | Med / high | Tiers A/B/D/E, `FakeTunnelProvider` in CI, consent screen, small-file bias, recorded live test now |
| Port 7844 blocked or `trycloudflare.com` filtered (campus!) | Med-high on campuses / med | HTTP/2 retry, direct tiers, hotspot (design 03), manual URL |
| UPnP/IPv6 unreliable or abused | High (unreliable) / low | Opportunistic, receiver race, hardening in s1.3 |
| Sender offline or asleep mid-transfer | High / med | UX line, sleep inhibitor, resume via new link |
| Link leakage via chat apps | Med / high | Warning, claim binding, approval code, short expiry |
| Antivirus/EDR flags cloudflared | Low-med / med | Pinned hash, docs, optional bundling |
| Pure-Dart AES-GCM too slow | Med / low-med | Isolate per connection; benchmark gate; native via `cryptography_flutter` in the app layer only |
| GitHub Pages name/availability | Low / low | Landing is optional for app receivers; constant `kLandingBase` |
| Orphan processes / stale mappings | Med / low | pidfile, startup sweeps |

### 5.6 Open questions for the user

1. **IP privacy default.** Should "Automatic" offer direct paths (faster, independent of Cloudflare, but the link holder sees your public IP) or default to tunnel-only with direct opt-in? Recommendation: tunnel-first when the receiver is a stranger link, direct allowed when you toggle it; or Automatic with the one-line disclosure. Your call affects default UX.
2. **Terms risk.** Ship Cloudflare Quick Tunnel as the default internet path despite "testing and development", no SLA and the unclear large-file clause (with a first-use consent screen and instant fallbacks)? Alternative: zrok-first (needs an account token) or direct-only.
3. **Bundle or download cloudflared?** Download-on-first-use with pinned hash (small installers, needs network, AV timing) vs bundling in the Windows installer and AppImage (+40-55 MB, offline-ready, ship Apache-2.0 notices). Recommendation: bundle on Windows, download on Linux/AppImage.
4. **Browser receiver and Pages name.** Is "recipient needs no install" required for v1 (then Inc 5c moves into Inc 5 and `libreshare.github.io` must be reserved now), or is "recipient installs the app, landing page shows how" acceptable?
5. **Android sender scope.** Accept "Android sends links only via direct tiers (Wi-Fi, best effort) and receives anything", or invest in the experimental cloudflared-on-Android path (jniLibs + GOOS=android build, no official support)?

## Sources (all accessed 2026-11-03; "search summary" = web-search digest, not a direct page read)

- S1 https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/ - limits, `--allowed-mail`, interactive-only (page read).
- S2 https://developers.cloudflare.com/changelog/post/2026-10-02-protected-quick-tunnels/ - changelog 2 Oct 2026 (page read; does not state default explicitly).
- S3 https://blog.cloudflare.com/protected-quick-tunnels/ - "Omitting the flag leaves public tunnels unchanged" (search summary); also https://daily.dev/posts/protected-quick-tunnels-simple-accountless-authentication-for-your-next-dev-project-1zufe0ysm (opt-in, cloudflared 2026.9.3+, secondary).
- S4 https://api.github.com/repos/cloudflare/cloudflared/releases/latest - 2026.10.7, 2026-10-30, assets + SHA-256 digests; repo license Apache-2.0 via https://api.github.com/repos/cloudflare/cloudflared.
- S5 https://developers.cloudflare.com/cloudflare-one/faq/cloudflare-tunnels-faq/ and https://www.cloudflare.com/service-specific-terms-application-services/ - large-file/CDN clause.
- S6 https://developers.cloudflare.com/workers/platform/limits/ (100 MB request body, Free) and https://fast.io/resources/cloudflare-upload-limit/ (upload cap = request body; secondary).
- S7 https://github.com/cloudflare/cloudflared/issues/793 - Termux/Android `[::1]:53`, no official fix.
- S8 https://pub.dev/packages/cloudflared_tunnel - Android-only gomobile plugin.
- S9 https://github.com/termux/termux-packages/wiki/Termux-and-Android-10 and AOSP sepolicy "Enforce execve() restrictions for API > 28" (search results).
- S10 https://zrok.io/pricing/ - Free plan, interstitial.
- S11 https://api.github.com/repos/openziti/zrok/releases/latest - v2.0.9 2026-10-31 assets; license Apache-2.0.
- S12 https://docs.zrok.io/docs/guides/self-hosting/interstitial-page/ (search summary; fetch blocked); S12b https://netfoundry.io/docs/zrok/how-tos/shares/share-http-proxy (`zrok2`, `--headless`; search summary).
- S13 https://ngrok.com/pricing. S14 https://pinggy.io. S15 https://tailscale.com/kb/1223/funnel. S16 https://merginit.com/blog/19062026-free-developer-tunnels-comparison (19 Jun 2026, secondary). S17 https://github.com/ekzhang/bore (search summary). S18 https://github.com/robbie-cahill/tunnelmole-client. S19 https://serveo.net/docs and https://jsr.io/@hongminhee/localtunnel (July 2026 changelog, secondary).
- S20 https://developers.cloudflare.com/r2/pricing/ and S6 Workers limits.
- S21 https://pub.dev/packages/port_forwarder and https://pub.dev/packages?q=upnp (upnp_client 1.5.0). S22 https://www.rfc-editor.org/rfc/rfc6887 (PCP, IPv6 firewall control, THIRD_PARTY); NAT-PMP is RFC 6886. S23 https://en.wikipedia.org/wiki/Internet_Gateway_Device_Protocol. S24 https://www.helpnetsecurity.com/2020/06/09/cve-2020-12695/ (CallStranger).
- S25 https://pulse.internetsociety.org/blog/18-years-later-ipv6-reaches-majority (50.10% on 28 Mar 2026). S26 https://www.prichter.com/imc176-richterA.pdf (IMC 2016 CGN study, text extracted locally). S27 https://arxiv.org/pdf/2510.27500 (DCUtR, 70% +/- 7.1%). S28 https://pub.dev/documentation/quic_lib/latest/ (pure-Dart QUIC, maturity unverified).
- S29 https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits. S30 https://web.dev/articles/files/save-a-file (updated 2026-06-26). S31 https://fedoramagazine.org/control-the-firewall-at-the-command-line/ (FedoraWorkstation zone ports 1025+). S32 https://dart.googlesource.com/sdk.git/+/8a43a891f3dc3c47ae659a5e99ffc5d3eb44f76e%5E%21/ (`CREATE_NO_WINDOW` handling). S33 https://www.elastic.co/guide/en/security/current/potential-protocol-tunneling-via-cloudflared.html and Sigma DNS rule https://detection.fyi/sigmahq/sigma/windows/dns_query/dns_query_win_cloudflared_communication/; S33b https://tools.malwaretips.com/file-scan/cdb5d4432f6ae1595654a692a51308b69d2bf7af961f5578d9391837cf072df9 (secondary). S34 https://developers.cloudflare.com/tunnel/troubleshooting/ (7844, QUIC/HTTP2; search summary). S35 https://stackharbor.com/en/knowledge-base/cf-quick-tunnel-trycloudflare-guide/ (api.trycloudflare.com; secondary); S35b https://www.rfc-editor.org/rfc/rfc6092. S36 https://git.nixnet.services/curben/cloudflared-mirror/commit/0924549efdecf5d32e2e91686fcef3ed3ab5952e (TUN-4811 `userHostname`). S37 https://bloggeek.me/webrtcglossary/stun/ (public STUN has no guarantee, 4 Feb 2026). S38 https://pub.dev/packages/app_links. S39 https://github.com/cloudflare/cloudflare-docs/issues/28227 (config.yml vs quick tunnels, closed 13 Oct 2026).
