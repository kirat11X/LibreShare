# Design 02 - Free internet rendezvous and presence for paired devices

Status: proposal for orchestrator review. Date: 2026-11-03. Scope: docs only; no repository code or system state was changed.
Binding constraints: everything $0 for users and maintainers (no card, no server or account the project operates); Linux + Windows first-class; Android best effort.
Evidence tags: `[Sn]` = source list at the end (fetched 2026-11-03). `[P]` = my own probe run on 2026-11-03 (section 2.2). `UNVERIFIED` = not confirmed by a fetched source or probe; test before relying on it.

## 0. Verdict: GO-WITH-CAVEATS

AirDrop-like "my paired device is online and here is how to reach it", across different networks, **can be done at $0 with no server we run**. Chosen design: sealed (end-to-end encrypted) presence records and offer mailboxes published to **several public Nostr relays** (NIP-01 addressable events, kind 30078), keyed by pseudonymous ids derived with HKDF from a 256-bit secret exchanged by QR. Backup backend: an ntfy-compatible HTTP topic (ntfy.sh or self-hosted). Last resort: the manual tunnel link/QR already in spec s7.5. Rendezvous carries signaling only; bytes keep flowing over the existing ladder (direct, then sender-hosted tunnel).

| Decision | Value |
|---|---|
| Primary backend | `NostrBackend` (>= 3 public relays in parallel, user-editable list, self-host = same code with your own relay URL) |
| Backup backend | `NtfyBackend` (low-rate mode, 250 msgs/day/IP budget) |
| Pairing | QR (or pasted code) carries 256-bit secret `S`; handshake yields pair key `K_pair`; pairwise, not group |
| Hole punching | **No** (ADR: out of ladder). Reflexive candidates stay representable for later |
| UPnP/NAT-PMP/PCP | **Yes, as a `TunnelProvider` ("portmap"), stretch 6b, default OFF** until live-tested |
| New increment | Inc 6 after Inc 5 (needs identity/consent from Inc 3, ladder from Inc 4, tunnel from Inc 5) |

Caveats the user must accept (details in section 7.4):
1. Public relays are best effort, no SLA. We mitigate with N relays, backup backend, self-host docs, and graceful degradation to today's manual link flow.
2. Presence is "seen N minutes ago", not guaranteed real time. Android presence only while Receive mode (design 01) or the app is foreground; Doze suspends network access [S30].
3. Relays see IP addresses, timing and sealed-blob sizes (not contents, names or addresses).
4. The data path across the internet still needs the **sender** to host a tunnel (cloudflared on desktop) or a port-mapped origin. Android as an internet *sender* stays unsupported (spec s7.4); Android as receiver works (it pulls outbound, which also works behind carrier-grade NAT).

## 1. Requirements and non-goals

| ID | Requirement |
|---|---|
| R1 | Rendezvous is signaling/presence only: who is online, current candidate addresses, a sender-hosted `tunnelOffer`, fingerprint. No file bytes, no file names, no manifests. |
| R2 | Only **paired** devices (QR-exchanged secret + pinned fingerprint) can read or write each other's channels. Pairing is explicit and user-confirmed on both devices. |
| R3 | $0 forever: no payment method, no account owned by the project, no server operated by maintainers. Every endpoint is replaceable by a user-run one (relay URL setting). |
| R4 | Relay operators and other relay users learn nothing but opaque ids, sizes, timing and IPs. |
| R5 | Failure is graceful: all backends down => LAN discovery, QR/manual IP and manual tunnel link still work unchanged. |
| R6 | Pure Dart in `packages/libreshare_core` (no Flutter); headless-testable with no internet. |
| R7 | Rendezvous never bypasses consent: an offer received over rendezvous always prompts (no auto-accept in v1), and mTLS pinning / tunnel E2E remain the only trust anchors for data. |

Non-goals: discovering **unpaired strangers** over the internet; accounts or contact books; a project-run directory/relay; NAT hole punching in v1; TURN/relayed data; push to sleeping Android (FCM needs a Google-owned Firebase project; UnifiedPush is UNVERIFIED future work).

**Why no public (stranger) discovery.** A global "who is nearby/online" namespace on public relays needs a well-known channel anyone can write to. Spec s5 already treats a rogue device spamming prompts as a primary threat; on the LAN it is bounded by the broadcast domain. Globally it is unbounded: unsolicited-file spam (abusive aliases, file names or images), harassment, and enumeration of who runs LibreShare with their IP. Mitigations would require an operator (reputation, blocklists, captcha), which violates R3. Strangers keep today's paths: same-LAN discovery, or an explicit tunnel link/QR that a human shares.

## 2. Survey of free building blocks (Nov 2026)

Scale: Y = meets, ~ = partial/risky, N = fails. Columns: **$0** = free forever without a card; **NoAcct** = no account owned by the project; **Avail** = availability/SLA; **ToS** = abuse/terms risk; **Priv** = metadata privacy; **Dart** = pure-Dart implementability in `libreshare_core`.

### 2.1 Candidates

| Block | $0 | NoAcct | Avail | ToS | Priv | Dart | Notes and verdict |
|---|---|---|---|---|---|---|---|
| **Public Nostr relays** | Y | Y | ~ | ~ | ~ | Y | Many independent operators (a March 2026 essay cites roughly 900 public relays in 2023, secondary); NIP-01 addressable events replace in place, NIP-40 expiry, tag/author filters [S1][S2][S3]. Most big relays are strfry and free; some are paid or whitelisted (nostr.wine: `payment_required`, `restricted_writes`) [P]. Relay churn is real (2 timeouts and 1 dead DNS in my 12-relay sample) [P]. No ToS found that forbids opaque app data, but nos.lol/nostr.mom ToS text was not retrievable: UNVERIFIED. **PRIMARY** |
| **Public MQTT brokers** | Y | Y | N | N | N | Y | HiveMQ: "must not be used in Production, Dev, Staging or UAT", may ban clients, treat every message as public [S4]. Mosquitto: asks users not to "abuse or rely upon it for anything of importance", anybody could be listening [S5]. EMQX: testing broker, messages visible to others [S6]. `mqtt_client` 10.14.0 is pure Dart, MQTT 3.1.1 only [S7]. Retained messages + LWT would be ideal, but ToS forbids shipping on them. **Reject** (dev/test only) |
| **Mainline DHT (BEP 44)** | Y | Y | ~ | Y | ~ | ~ | No operator; signed mutable items, 1000 B max, ~2 h expiry unless re-announced, salt gives many slots per key [S8]. Needs UDP (blocked on some campus/corporate nets). No Dart package found: ~1.5 kLOC from scratch (bencode, KRPC, routing table, tokens). Pkarr relays give HTTP access: `relay.pkarr.org` answered 200 [P], `pkarr.pubky.app` timed out [P]; Pkarr README gives no relay list [S9]. **Future backup #2**, not v1 |
| **libp2p / IPFS** | Y | Y | ~ | ~ | ~ | ~ | `dart_libp2p` 4.12.0 exists: hole punching, relay, Noise, no QUIC (custom UDX), DHT/pubsub in separate packages, 25 direct deps, 8 likes / 2.79k downloads [S10]. Joining the public Amino DHT/bootstrap set for a non-IPFS app is heavy and rude to the network. **Reject for v1** |
| **Public STUN** (Google, Cloudflare) | Y | Y | Y | ~ | ~ | Y | `stun.l.google.com:19302`, `stun1...`, `stun.cloudflare.com:3478` all answered a UDP Binding Request in 23-24 ms [P]. Google publishes no terms for it; Cloudflare lists the address in TURN docs without terms [S11]: UNVERIFIED. Reveals your IP to them. ~100 LOC (RFC 8489). **Use** only for CGNAT detection and reflexive candidates |
| **WebRTC data channels** | ~ | Y | ~ | Y | ~ | ~ | `webrtc_dart` 0.25.3 (MIT, pure-Dart ICE/DTLS/SCTP, optional OpenSSL FFI for SRTP only, 2,661 tests) exists [S12]. But: no free TURN (Cloudflare TURN is free only with its SFU, else $0.05/GB [S11]), so ~30% of pairs need a relay we cannot pay for (s5.4); pure-Dart SCTP/DTLS throughput UNVERIFIED; LSP-1 is HTTP/TCP, not data-channel framed. **Stretch ADR**, not v1 |
| **ntfy.sh** | Y | Y | ~ | ~ | ~ | Y | Anonymous HTTP pub/sub; topic "is essentially a password" [S13]. Public limits: 250 messages/day, 4096 B/message, 60-request burst then 1 per 5 s, 30 connections, 200 MB/day bandwidth, 12 h cache, repeat offenders IP-banned [S14][S15]. Single operator, paid tiers exist. Logs IPs for rate limiting, no message-content logging by default [S16]. Pure `dart:io` HTTP. **BACKUP** (low-rate mode) |
| **GitHub Gists/Issues** | Y | N | Y | N | N | Y | Needs a GitHub account + token per user; poll-only; API ToS lets GitHub suspend "abuse or excessively frequent requests" at its discretion, no token sharing, no bot accounts [S17]. **Reject** |
| **Cloudflare Workers + Durable Objects** | ~ | N | Y | Y | ~ | Y | Free plan: 100k requests/day, 13,000 GB-s/day, SQLite-backed DOs only, 20:1 WebSocket message ratio; past the limit operations fail (no overage bill) [S18][S19]. Card requirement not stated on the pages: UNVERIFIED. A shared project deployment = us operating a service (R3). **Optional self-deploy recipe only** (a relay worker per power user) |
| **Firebase Spark / Supabase free** | ~ | N | ~ | Y | N | ~ | Spark: no payment method, but 100 simultaneous connections, 10 GB/month, disabled past limits [S20]. Supabase free projects pause after a week of low activity [S20]. Account + vendor SDK per deployer. **Reject** |
| **Tailscale / Headscale / ZeroTier / NetBird** | ~ | N | Y | ~ | Y | N | Tailscale Personal $0, 6 users, every user signs in through an IdP [S21]; ZeroTier free 10 devices and NetBird cloud free 5 users/100 machines per secondary sources [S22]. Each needs its own daemon + account; Headscale is a server. Not embeddable. **Reject** (users may already run LibreShare over a tailnet via manual IP) |
| **Matrix** | ~ | N | ~ | ~ | ~ | ~ | Account per user on a homeserver, heavy sync API, matrix.org terms UNVERIFIED. **Reject** |
| **IRC** | Y | Y | ~ | N | N | Y | Libera.Chat: "may not be used to facilitate communication between bots" and relaying data "not meant for a human to directly observe" [S23]. **Reject** |
| **Generic WebSocket relay** | N | N | - | - | - | Y | Requires a server. Equivalent to self-hosting a Nostr relay (strfry in Docker); supported as a URL in settings, not as a default |

### 2.2 My probes, 2026-11-03 (NIP-11 GETs plus at most 5 tiny anonymous events per relay, all expiring or ephemeral)

Probe: a fresh random secp256k1 key signs (hand-written BIP-340, public-key check against the BIP test vector) kind 30078 addressable events with a random `d` tag, a random 16-byte `t` tag, `expiration` +10 min, content 300 B then 4 KiB; plus an ephemeral kind 25300; a second connection subscribes by tag filter. Scripts lived in the session scratchpad and were not committed (propose `tools/rendezvous_probe/` in Inc 6).

| Result | Relays |
|---|---|
| Accepted anonymous kind 30078 (with `t`, `d`, `expiration`; 4 KiB content), replace-in-place verified (newer event with same `d` returned alone), no PoW/AUTH/payment | relay.damus.io (503 on my first two attempts, OK on third), nos.lol, relay.primal.net, nostr.mom, offchain.pub, relay.nostr.net, relay.snort.social, relay.wellorder.net, nostr.oxtr.dev (9/9 on the final run) |
| Live fan-out of an event to a tag-filtered subscriber | 184 ms (primal) to 3,660 ms (relay.nostr.net); median about 450 ms |
| Ephemeral kinds | strfry relays also kept an ephemeral event for a late subscriber (retention is strfry-specific, so do not rely on it); snort (memlay) and wellorder do not store it. **Use addressable kind 30078, not ephemeral** |
| Failures | relay.nostr.band and nostr-pub.wellorder.net: handshake timeout; relay.nostr.bg: DNS gone; nostr.wine: paid |
| NIP-11 limits seen | `max_message_length` 128 KiB-1 MB; `max_subscriptions` 20-300; nostr.wine adds `created_at_upper_limit: 300` s (clock must be right) |

Implication: kind 30078 (NIP-78 "Application-specific Data" [S2]) is the safest kind (most likely to pass kind whitelists), a 4 KiB envelope fits everywhere, and with `limit`-less author-filtered REQs the relay returns only the single latest event per slot.

## 3. Recommended design

### 3.1 Architecture

```
 Engine (ConnectionManager, Inc 4)           RendezvousService (new, rendezvous/)
   candidates <---- RendezvousCandidateSource <--- PresenceCache <--- verify(sig, seq, ttl)
   tunnelOffer  ----> sendOffer()  --seal--> EnvelopeCodec --> RendezvousBackend.put()
   incomingOffer <--- verify+dedupe <--open-- EnvelopeCodec <-- RendezvousBackend.watch()
 PairingService --K_pair--> ChannelDeriver (HKDF) --seed--> backend.addressFor(seed)
 Backends: NostrBackend (primary) | NtfyBackend (backup) | InMemoryRelayBackend (tests)
 Gate: ReceiveController (design 01) AnnouncePolicy none => publish no presence; contacts|everyone => paired peers only
```

Rendezvous is one more **candidate source** in the ADR 0002 sense: it contributes `Candidate`s (peer addresses from presence) and a `tunnelOffer` to the existing ladder; `ConnectionManager` is unchanged. Rendezvous start/stop is driven by `ReceiveGate`/app lifecycle, not by the transfer code.

### 3.2 Pairing (QR yields a 256-bit secret)

Invite URI (extends spec s4.2 item 6; the Inc 3 QR should already reserve `s`):
`libreshare://pair?v=1&s=<32 B b64url>&id=<deviceId>&fp=<SHA-256 b64url>&n=<alias>&r=<relay hint hosts, optional>`; about 180 chars, QR version about 9-11 depending on relay hints. Desktops without cameras show/paste the same string (52-char base32 of `S` + fingerprint words); short typed codes would need a PAKE and no maintained pure-Dart PAKE was found: UNVERIFIED, out of scope.

| Step | Inviter A (shows QR) | Scanner B |
|---|---|---|
| 1 | Generate `S` (CSPRNG, 32 B), valid 10 min, single use. Derive `K_boot` and bootstrap channels with `HKDF(S,"boot",role)` (roles `inviter>scanner` / `scanner>inviter`, because B's fingerprint is not yet known), subscribe | Scan; derive the same |
| 2 | | Send `hello` sealed under `K_boot`: `{deviceId, alias, certDer, nonceB, sigB}`; `sigB` = ECDSA-P256 over `"LSP-R1-PAIR" ‖ H(S) ‖ nonceB ‖ fpA ‖ fpB` |
| 3 | Verify `sigB`. UI: "Pair with *alias*? SAS 123456" (reuse spec s5 SAS over fpA, fpB); explicit Accept, otherwise discard (a photographed QR cannot pair silently) | Shows the same SAS |
| 4 | Send `accept` sealed: `{certDer, alias, nonceA, sigA}` | Verify `sigA` |
| 5 | `K_pair = HKDF-SHA256(ikm=S, salt=nonceA‖nonceB, info="LSP-R1 pair"‖min(fp)‖max(fp), L=32)`; store in `SecretStore` (D3) with peer cert + fingerprint (D1); **erase `S`**; mark `S` spent | same |

`S` is high-entropy, so no PAKE is needed; its only job is a 10-minute authenticated bootstrap. After step 5, anyone holding the QR photo is useless. Forward secrecy is not provided by `K_pair` (see threat T7).

### 3.3 Pseudonymous channels, keys, sealed envelopes

```
epoch e   = floor(unixSeconds / 86400)            // UTC day; peers accept e-1, e, e+1 (clock skew)
dir       = "lo>hi" | "hi>lo" by comparing uppercase fingerprints   // two one-way channels per pair
seed(slot,dir,e) = HKDF-SHA256(K_pair, salt="LSP-R1", info="chan"||slot||dir||be64(e), 32)   // slot: 0 presence, 1 mailbox
aeadKey(dir,e)   = HKDF-SHA256(K_pair, salt="LSP-R1", info="aead"||dir||be64(e), 32)
Nostr address: sk = seed (re-derive with counter if >= curve order), pk = BIP-340 x-only(sk), d = hex(HKDF(seed,"d")[0..16])
ntfy address : topic = "ls" || base32(SHA-256(seed)[0..20])
envelope     = 0x01 || nonce(12, CSPRNG) || AES-256-GCM(pad(plaintext)) || tag(16)      // pad to 512/1024/2048/4096 with length prefix
AAD          = "LSP-R1" || slot || dir || be64(e) || backendName
Nostr event  = kind 30078, tags [["d",d],["expiration",now+900]], content = b64url(envelope), created_at = max(now, last+1), sig = BIP-340(sk)
```

- Readers filter `{"kinds":[30078],"authors":[pk(e-1),pk(e),pk(e+1) for every peer],"since":now-86400}`. Because `sk` is derived from `K_pair`, **only paired devices can publish under those authors**: a stranger who scrapes the public `d`/author values cannot inject events that survive the relay's `authors` filter, so no junk reaches our decryptor. This is the main spam control (T3).
- The relay learns: rotating pseudonymous pubkey per direction per day, an opaque `d`, size bucket, timing, and the IPs of publisher and subscriber (so it can infer "these two IPs talk" within an epoch; R4 accepts this, optional SOCKS5/Tor is an open question).
- All strings in the event are `[A-Za-z0-9_-]`, so any JSON encoder yields the NIP-01 canonical serialization used for the event id (no escaping subtleties).
- `created_at` must be within relay limits (nostr.wine allows +300 s) [P]; on `invalid:` OK replies mark the relay "clock-incompatible" and show "check your clock".

### 3.4 Sealed records (inside the envelope, canonical JSON)

```json
// PresenceRecord (slot 0), about 600 B before padding
{"t":"presence","v":1,"deviceId":"uuid","alias":"Ravi-ThinkPad","platform":"windows","fp":"64 HEX",
 "seq":1812,"issuedAt":"2026-11-03T10:00:00Z","ttl":600,
 "addrs":[{"ip":"192.168.1.23","port":53318,"if":"wifi","kind":"lan"},{"ip":"2001:db8::7","port":53318,"if":"ethernet","kind":"ipv6"}],
 "caps":["resume","tunnel","sas","rdv1"],"sig":"<ECDSA P-256 r||s, b64url>"}
// SessionOffer (slot 1) - one pending offer per direction
{"t":"offer","v":1,"offerId":"uuid","sessionId":"uuid","seq":1813,"issuedAt":"...","expiresAt":"...",
 "summary":{"files":3,"totalSize":1288490188},"tunnelOffer":{"provider":"cloudflare-quick","url":"https://x.trycloudflare.com/t/<token>","keyB64":"...","expiresAt":"..."},"sig":"..."}
// OfferReply (receiver->sender, slot 1): {"t":"reply","offerId":"uuid","decision":"accept|reject|busy","seq":...,"sig":"..."}
```

- `sig` = ECDSA-P256/SHA-256 by the **device identity key** (same key as the mTLS cert) over `"LSP-R1-REC" || canonicalJson(record - sig) || pairId`. A leaked `K_pair` alone cannot forge records (T7).
- Replay: per-peer monotonic `seq` persisted; reject `seq <= last`; reject `issuedAt` outside +-5 min (offers: `expiresAt` in the past); remember `offerId` 24 h. Presence TTL 600 s: older = "Offline/Last seen".
- `tunnelOffer` is validated like any untrusted URL before use: `https` (or `portmap` pinned-cert URL), public routable host only (no loopback/private/link-local: SSRF), sizes capped by the existing 256 KiB rule. File names never travel here; the receiver sees them only after fetching the sealed manifest (spec s4.5) and then asks the user.

### 3.5 How a sender learns a paired receiver is online and gets an address

1. Startup: load `paired` devices; open the backend; one REQ per relay with all peers' author keys (3 epochs each). The relay returns the **latest stored presence** per author before EOSE, then streams live updates. Estimated readiness 0.5-1.5 s after relay connect (not measured).
2. Presence cache state per peer: `online` (record age <= ttl), `recent` (<= 24 h, shows "last seen"), `unknown`. The Home screen merges LAN-discovered peers and rendezvous peers by `deviceId`/fingerprint; one row, best path wins.
3. Fresh check: when the user opens "Send", publish a signed `probe` (slot 1); devices in Receive mode answer with a new presence immediately (observed fan-out 0.2-3.7 s [P]). No answer within 5 s => treat as `recent`.
4. Candidates: `addrs` from the verified record become `Candidate`s for tiers 1/2 of the ladder; connection attempts are raced with the existing 3 s per candidate and mTLS pinned to the **paired fingerprint** (a wrong host fails TLS, so a malicious address is only a DoS). `wan`/`mapped` address kinds are only advertised if the user enabled direct-internet receive (default OFF, section 3.7).
5. No usable direct path: the sender prepares the tunnel (provider order `portmap`, `cloudflared`, `zrok`), publishes the `SessionOffer`, and waits. The receiver (online) verifies, shows the consent prompt, fetches the sealed manifest through the tunnel, and replies `accept`/`reject` over rendezvous (also acknowledged in-tunnel, section 7.3). If the receiver is offline the offer waits in the mailbox until `expiresAt` (default min(tunnel expiry, 1 h)); the sender UI says "Waiting for *alias* to come online" with Cancel.

### 3.6 Relay selection, rates, battery and traffic

- Default list of 5-7 relays in `kDefaultRelays`, user-editable, optional signed `relays.json` fetched from the project's GitHub raw URL (free) to refresh defaults without a release; failure to fetch is silent.
- Per pair, `order = relays.sortBy(HMAC(K_pair, url))`; publish to the first 3 healthy, subscribe to first 4. Both sides converge without coordination; dead relays are skipped by health (connect timeout 8 s, jittered backoff 5 s to 5 min, never faster).
- Client rate caps (token bucket): <= 20 EVENTs/min/relay, presence <= 1 per 5 min per peer plus debounced (2 s) change-triggered republish, offers <= 1 per 60 s per peer; honor `rate-limited:` OK replies by doubling the interval. ntfy mode: <= 100 messages/day/IP budget, presence on change + 30 min heartbeat, no probes.
- Traffic (computed, not measured): keep-alive ping every 45 s on 3 relays about 0.9 MB/day; one presence event about 1.7 KB on the wire; 5 peers x 12 beats/h x 24 h x 3 relays = about 7 MB/day upload plus similar download if always online. A phone that is foreground 2 h with 2 peers uses under 0.5 MB.
- Android: network is suspended in Doze and App Standby; the sanctioned wake path is FCM [S30], which needs a Google-owned Firebase project (not $0-neutral, not F-Droid friendly), so **not used**. Presence runs only while the design-01 `ReceiveService` (connectedDevice FGS, receive window) or the UI is active; on resume the app does one REQ with `since` to collect pending offers. Desktop runs presence while the app/tray runs.

### 3.7 NAT traversal facts and the free "direct reachability" tier

- **UDP hole punching in pure Dart** is possible at socket level (`RawDatagramSocket`) but useless here: LSP-1 is HTTPS/TCP and there is no maintained pure-Dart QUIC (`dart_libp2p` documents "does not support QUIC", uses its own UDX [S10]); we would be writing a reliable encrypted UDP transport.
- **TCP simultaneous open**: the Dart SDK has `Socket.connect(sourcePort:)` and `ServerSocket.bind(shared:)` (read in SDK 3.13.7 `lib/io/socket.dart`), but SO_REUSEADDR/SO_REUSEPORT interplay on Windows/Android is UNVERIFIED.
- **How often does punching fail?** Largest public measurement (IPFS DCUtR, 4.4 M attempts, 85k networks): 70% +- 7.1% success of the punch stage, TCP about equal to QUIC; this is conditional on reaching that stage and excludes about 29% of data points where relay or public-address discovery failed; volunteers skew technical [S24][S25]. So expect roughly 30% failures at best, worse with our multi-second signaling jitter ([P] fan-out up to 3.7 s) than libp2p's RTT-synchronized dialing. Carrier-grade NAT: found in 17-18% of eyeball ASes and over 90% of cellular ASes (2016 data; I found no 2025-26 figure) [S26]. A receiver on mobile data is therefore almost always behind CGNAT: it can only pull outbound, which is exactly the tunnel model.
- **Decision: no hole punching in the ladder (ADR 0003).** `CandidateKind.reflexive` stays representable so it can be added without a wire change.
- **UPnP IGD / NAT-PMP (RFC 6886) / PCP (RFC 6887)** are free and need no rendezvous. Recommendation: add **`PortMapTunnelProvider`** (stretch 6b) *as a `TunnelProvider`*, first in order `[portmap, cloudflared, zrok]`, not as a new ladder tier and not by exposing the mTLS API:
  - Sender maps a TCP port, serves the existing token-gated, AES-256-GCM `TunnelOriginServer` over HTTPS with the sender's identity cert on that port; `tunnelOffer.provider = "portmap"`, URL `https://<wan-ip>:<port>/t/<token>`, receiver pins `fp`.
  - Gate: use only if STUN reflexive IPv4 == gateway-reported external IP (otherwise CGNAT: skip); lease <= 1 h, delete the mapping when the session ends; per-transfer only, never a standing mapping.
  - Benefit: removes the Cloudflare dependency and the 100 MB/200-request caveats for home users with UPnP/PCP and a public IP; also gives Android senders a path. Prevalence of working UPnP/PCP on target routers is UNVERIFIED: measure on the team's routers (manual matrix).
  - Dart: `port_forwarder` 1.0.0 covers UPnP/NAT-PMP/PCP but is new (441 downloads), lists no Android support and its `xml` constraint fails the latest [S27]; plan to write our own thin client (~400 LOC; SSDP needs the Android MulticastLock) behind `PortMapper` with a fake IGD for tests.
  - Default OFF in Settings until live-tested; global IPv6 candidates (no NAT) are carried in presence and raced like any other.

### 3.8 Backup backend (`NtfyBackend`) and degrade ladder

`PUT/POST https://ntfy.sh/<topic>` with the b64url envelope (<= 4096 B), `GET /<topic>[,<topic2>...]/json?since=<ts>` streaming (comma multi-topic: verify in Inc 6, UNVERIFIED). No replace semantics: reader keeps the highest `seq`. Topic rotates daily with the epoch, so the "topic is a password" property holds. Self-hosting is documented (Docker) because the public instance is a single operator [S13]. Order of use: Nostr (any 1 of N relays up) -> ntfy -> nothing (manual link flow). Both can run simultaneously; the service dedupes by `(deviceId, seq)`.

## 4. Threat model (mirrors spec s5)

| ID | Threat | Mitigation | Test |
|---|---|---|---|
| T1 | Relay operator reads or correlates | AES-256-GCM envelope, opaque rotating author/`d`, size buckets, daily rotation; residual: IP, timing, pair-linkage within a day (documented) | `envelope_opacity_test`, `channel_rotation_test` |
| T2 | Relay forges, replays, delays or drops | AEAD + ECDSA identity signature, per-peer `seq`, `issuedAt`/`ttl`, `offerId` memory; drop/delay = availability only, then backup backend | `replay_test`, `forged_record_test`, `relay_withhold_test` |
| T3 | Other relay users spam or scrape our slots | `authors` filter + `sk` derived from `K_pair` (strangers cannot publish under it); scraped data is opaque; per-peer offer rate limit | `foreign_author_test`, `offer_rate_limit_test` |
| T4 | Network attacker on path | `wss://` with system roots; AEAD regardless; data path keeps mTLS pinning / tunnel E2E (spec s5) | `mitm_test` (extended), `tls_required_test` |
| T5 | QR photographed or shoulder-surfed | `S` single-use, 10 min, inviter must Accept after seeing alias + SAS, `S` erased after pairing, optional "pair on LAN only" mode | `pairing_race_test`, `pairing_expiry_test` |
| T6 | Stolen paired device | Identity key + `K_pair` in OS `SecretStore`; revoke: delete local `K_pair`, publish signed `revoke(fp)` to remaining peers, who prompt "remove it?"; rendezvous offers always prompt (no auto-accept); window = peers that have not yet processed the notice | `revoke_test`, `offer_always_prompts_test` |
| T7 | `K_pair` leaks alone (backup, forensics) | Records also need the peer's ECDSA identity signature; attacker can read relay traffic from the leak onward (no forward secrecy in v1; ratchet is future work) | `signature_required_test` |
| T8 | Malicious or buggy offer content (SSRF URL, oversized, hostile alias) | Signature from a *paired* fp; URL scheme/host validation (public routable only); size caps; alias sanitized before UI; sanitizer on manifest unchanged | `offer_validation_test`, `offer_fuzz_test` |
| T9 | Paired-but-abusive peer spams offers | 1 pending offer per peer, 1 offer/60 s, mute and unpair; consent prompt unchanged | `offer_rate_limit_test` |
| T10 | Relay disappears, bans us, rate-limits | >= 3 relays, health-based pick, backup backend, self-host docs, manual link fallback; low request rate and standard kind 30078 | `relay_failover_test`, `degrade_ladder_test` |
| T11 | Clock skew, epoch edges | Subscribe e-1..e+1; record window +-5 min; relay `created_at` rejection surfaced to the user | `clock_skew_test`, `epoch_boundary_test` |
| T12 | Presence leaks online hours | "Appear offline" (Receive mode Off => no presence); presence is per-peer sealed, never public | `receive_off_publishes_nothing_test` |
| T13 | Downgrade: attacker blocks relays to force manual flows | Manual flow is itself safe (fragment key + fp confirmation, spec s4.5) | existing tunnel tests |

Never log `S`, `K_pair`, seeds, derived keys, envelope plaintext, or tunnel fragments (CLAUDE.md rule extended); relay URLs and event ids are loggable.

## 5. Dart interface sketches

Module layout under `packages/libreshare_core/lib/src/rendezvous/` (all pure Dart; `dart:io` WebSocket/HTTP, `cryptography` HKDF/AES-GCM, `pointycastle` for secp256k1 and P-256):

```
rendezvous_backend.dart   channel_deriver.dart     envelope_codec.dart      records.dart (PresenceRecord, SessionOffer, OfferReply, Revoke)
rendezvous_service.dart   presence_cache.dart      rendezvous_candidate_source.dart   relay_selection.dart
pairing/{pairing_service,pairing_invite,pair_key_schedule}.dart      storage/paired_device_store.dart (D1 + D3 refs)
backends/nostr/{nostr_backend,relay_connection,nostr_event,bip340}.dart   backends/ntfy/ntfy_backend.dart   backends/memory/in_memory_relay.dart
portmap/{port_mapper,upnp_igd,nat_pmp,pcp,stun_client,portmap_tunnel_provider}.dart   (stretch 6b)
```

```dart
abstract interface class RendezvousBackend {           // like MdnsBackend / TunnelProvider
  String get name;                                     // 'nostr' | 'ntfy' | 'memory'
  ChannelAddress addressFor(Uint8List seed32);         // pure and deterministic; writer and reader agree
  Stream<EndpointHealth> get health;                   // per relay/server up/down for UI + selection
  Future<void> start();
  Future<void> stop();
  /// Replace-latest per address; completes when >= 1 endpoint acks (others continue in background).
  Future<PublishResult> put(ChannelAddress to, Uint8List sealed, {required Duration ttl});
  /// Stored-latest first (EOSE-style backlog), then live; de-duplicated across endpoints.
  Stream<SealedMessage> watch(Set<ChannelAddress> from, {Duration backlog = const Duration(hours: 24)});
}
final class ChannelAddress { const ChannelAddress({required this.readId, this.writeSecret, required this.slotId});
  final Uint8List readId; final Uint8List? writeSecret; final String slotId; }
final class SealedMessage { final ChannelAddress from; final Uint8List sealed; final DateTime relayTime; final String endpoint; }

final class PresenceRecord {
  final String deviceId, alias, platform, fingerprint;   // fingerprint = uppercase hex SHA-256 of DER cert
  final int seq; final DateTime issuedAt; final Duration ttl;
  final List<CandidateAddr> addrs;                       // ip, port, if, kind: lan|ipv6|mapped|wan|reflexive
  final List<String> caps;
  final Uint8List signature;                             // ECDSA P-256 by the device identity key
  Map<String, Object?> toCanonicalJson();                // sorted keys, no whitespace, excludes sig
}

abstract interface class PairingService {
  Future<PairingInvite> createInvite({Duration validFor = const Duration(minutes: 10)});  // uri + live status stream
  Stream<PairingRequest> get requests;                   // inviter side: scanner said hello (alias, SAS)
  Future<PairedDevice> redeem(String inviteUri);         // scanner side
  Future<PairedDevice> confirm(PairingRequest r, {required bool accept});
  Future<void> unpair(String deviceId, {bool announceRevocation = true});
  List<PairedDevice> get paired;                         // also feeds ReceiveVisibility.contacts and the trust store
}

abstract interface class RendezvousService {
  Future<void> start(); Future<void> stop();             // driven by app lifecycle and ReceiveGate
  void announce(LocalPresence p);                        // debounced; call on interface change
  Stream<PeerPresence> watch(String deviceId);           // online | recent(lastSeen) | unknown + verified addrs
  Future<OfferHandle> sendOffer(String deviceId, SessionOffer o);   // handle.replies: accept | reject | busy | expired
  Stream<IncomingOffer> get incomingOffers;              // verified, de-duplicated, rate-limited
  Stream<BackendStatus> get status;                      // for the "Internet: 3/5 relays" indicator
}
```

Engine wiring: `LibreShareEngine` owns `RendezvousService?` (null when the feature is off); `RendezvousCandidateSource` implements the Inc 4 candidate-source contract; incoming offers feed the same consent pipeline as `POST /sessions` (a `TransferSession` created in `PENDING` with `source: rendezvous`).

## 6. Headless test plan (no internet in CI)

| Layer | What |
|---|---|
| Unit (pure) | HKDF/KAT vectors; `ChannelDeriver` goldens (epoch edges, dir ordering, sk re-derive when >= n); `EnvelopeCodec` (tamper, wrong key, wrong AAD, padding buckets, truncation); **BIP-340 official test vectors** (sign + pubkey); NIP-01 event-id goldens; record canonical JSON + signature; `seq`/`issuedAt`/`ttl`/`offerId` replay rules with fake `Clock`; relay selection determinism (`HMAC(K_pair,url)`); URL/SSRF validator; rate-limit buckets |
| `InMemoryRelay` (fake) | NIP-01 subset in-process: EVENT/REQ/CLOSE/OK/EOSE, addressable replace (tie => lowest id), `authors`/`#d`/`kinds`/`since` filters, NIP-40 expiry via fake clock; fault knobs: drop, delay, duplicate, replay old event, reject with `rate-limited:`/`invalid:`, close socket, refuse connect |
| **Loopback WebSocket relay** | `test/helpers/loopback_nostr_relay.dart`: `HttpServer.bind(loopback)` + `WebSocketTransformer.upgrade` running the same relay logic, so `NostrBackend` is exercised over real sockets: reconnect with backoff, 3-relay publish/subscribe with 1 killed mid-run, dedupe across relays, oversize/malformed frames (hostile relay fuzz), slow relay, clock-rejecting relay |
| Pairing | happy path over `InMemoryRelay`; wrong/expired/reused `S`; two scanners racing (first Accept wins, second rejected); inviter declines; tampered `sigB`; SAS equal on both sides; unpair + `revoke` notice handling |
| Presence and offers | A sees B `online` within 3 s of B start; `recent` after TTL; `probe` => fresh presence; offer delivered once under duplicate relays; offer to an offline peer is delivered when it starts; expired offers dropped; receiver `reject` reaches the sender; no auto-accept |
| Two-engine internet test | `test/integration/rendezvous_two_engine_test.dart`: two engines, LAN discovery disabled, direct addresses deliberately unreachable, `FakeTunnelProvider`, only `LoopbackNostrRelay` x3 between them: pair by QR string, see presence, send 5 MiB, byte-identical result, `ConnectionManager` badge = Internet |
| Docker e2e | extend `tools/docker/compose.yaml`: a `relay` container (our own `tools/docker/fake_relay.dart`, deterministic) on `inet_net`; wifi and lan networks cut; transfer completes via tunnel offer; relay container stopped mid-wait => UI event `RendezvousDegraded`, then restored |
| Live (manual, opt-in) | `LS_RENDEZVOUS_LIVE=1`: run the probe from section 2.2 against the real default relays and record results in `docs/test-reports/`; repeat each sprint because relay policy drifts |
| Property/fuzz | envelope and record parsers never throw past the boundary; 10k random frames from a hostile relay; no unbounded memory (max frame 128 KiB, max 64 authors per REQ chunked) |

## 7. Increments, effort, risks, plan changes, open questions

### 7.1 Increment mapping

Prerequisites: identity key, `CertFactory`, `SecretStore`, SAS, trust store, consent (Inc 3); `Candidate`/`ConnectionManager` (Inc 4); `TunnelProvider`/`TunnelOriginServer`/`tunnelOffer` (Inc 5). Therefore a new **Increment 6 - Internet rendezvous**, and the current Sprint 6 (polish/packaging) becomes Sprint 7, or Inc 6a is the Sprint 6 core and polish is trimmed.

Small additions earlier (so nothing is redone): **Inc 3** reserves `s=` in the pairing QR, stores `pairedAt` and a nullable `K_pair` reference in D1/D3, and implements "Contacts only" visibility on that same record (design 01); **Inc 5** makes `TunnelProvider` an ordered list and lets `tunnelOffer.provider` be an open string.

| Step | Scope | Acceptance |
|---|---|---|
| 6.0 | `docs/protocol/LSP-R1.md`, schemas (`presence`, `offer`, `reply`, `revoke`, `pair-hello/accept`), ADR 0003 (no hole punching) | schema conformance tests green |
| 6.1 | Crypto core: `ChannelDeriver`, `EnvelopeCodec`, records, signing, replay rules, `InMemoryRelay` | all unit tests; BIP-340 vectors |
| 6.2 | `NostrBackend` + `LoopbackNostrRelay` tests | 3-relay failover test |
| 6.3 | `PairingService` + CLI `ls pair --show` / `ls pair --scan <uri>` / `ls peers` | pairing tests; two CLI processes pair via a loopback relay |
| 6.4 | `RendezvousService`, presence, `RendezvousCandidateSource`, engine + `ReceiveGate` hook | A sees B online <= 3 s; Receive Off publishes nothing |
| 6.5 | Offer flow + decision reply + LSP-1 s4.5 addition | two-engine internet test; Docker e2e with relay container |
| 6.6 | Flutter: Pair screen (show/scan QR), Paired devices list with Online/Recent badges, "Internet" relay status, relay list setting; Android lifecycle | widget tests; manual matrix (home router + campus + hotspot) |
| 6.7 stretch | `StunClient`, `PortMapTunnelProvider` (fake IGD tests), `NtfyBackend`, `tools/rendezvous_probe/` | fake-IGD tests; one recorded live mapping on a real router |

Acceptance additions (new IDs, to reconcile with design 01 which proposes FR-18/NFR-09): **FR-19** pair two devices by QR and see each other online across different networks <= 10 s after start; **FR-20** send to a paired device on another network via tunnel offer with consent; **FR-21** unpair/revoke stops presence and offers both ways; **NFR-10** $0: no paid dependency in `pubspec`/docs, every endpoint user-replaceable, CI has zero internet access to run rendezvous tests; **NFR-11** with all rendezvous backends unreachable, LAN and manual-link flows pass unchanged.

### 7.2 Effort (person-days, one experienced Dart dev; estimates, not measured)

| Work | Days |
|---|---|
| 6.0 docs/schemas/ADR | 1.5 |
| 6.1 crypto core + fake relay + tests | 3.5 |
| 6.2 Nostr backend (BIP-340 incl.) + loopback relay + tests | 5 |
| 6.3 pairing service + CLI | 3.5 |
| 6.4 presence + candidate source + engine hook | 3 |
| 6.5 offers + LSP-1 change + two-engine/Docker tests | 3.5 |
| 6.6 Flutter UI + Android lifecycle | 5 |
| **Core 6a total** | **about 25 (about one sprint for 2-3 contributors)** |
| 6.7 STUN + PortMap + fake IGD + ntfy + probe tool | about 9 (optional 6b) |

Minimum viable cut if time-boxed: 6.0-6.5 without UI beyond CLI (about 17 days) still demonstrates cross-network pairing, presence and offer in the Docker/CLI demo.

### 7.3 Changes required in the existing plan

1. **Spec s12:** add Increment 6 (above); shift polish to Sprint 7 or trim. **Spec s6/ADR 0002:** state that rendezvous is a candidate source and the tunnel provider list is ordered `[portmap, cloudflared, zrok]`; new ADR 0003 (no hole punching, no WebRTC in v1).
2. **LSP-1:** (a) s4.2 item 6: add the `libreshare://pair` URI; (b) s4.5: add a sealed **decision ack** `{offerId, decision}` (accept/reject) next to chunk acks, because consent cannot ride on `POST /sessions` when no direct channel exists; (c) `DeviceAddress` gains optional `kind` (lan, ipv6, mapped, wan, reflexive); `caps` gains `rdv1`; (d) `tunnelOffer.provider` may be `portmap`. Rendezvous wire formats live in new `docs/protocol/LSP-R1.md` + schemas, with conformance tests in the same PR (CLAUDE.md rule).
3. **Spec s5:** add rows for pairing and rendezvous threats (section 4 here). **Spec s9:** add Pair screen and "Internet" status chip. **s16 risks:** add "public relay disappears".
4. **CLAUDE.md:** map entry `rendezvous 9.0` (storage: pairing record in D1 + `K_pair` in D3); rule "never log `S`, `K_pair`, seeds"; gotcha "Rendezvous tests use InMemoryRelay/LoopbackNostrRelay unless `LS_RENDEZVOUS_LIVE=1`". **traceability.md:** FR-19..21, NFR-10..11.
5. **Design 01 integration:** `AnnouncePolicy.none` => no presence; `contacts` => presence only to paired peers; `everyone` does not extend rendezvous beyond paired peers.
6. **Spec s1 deps:** none new for the primary path (`cryptography`, `pointycastle`, `crypto` already listed); WebSocket/HTTP from `dart:io`. `bip340` 0.3.1 exists (MIT, self-described "not safe cryptography") [S28]; we use our own ~80-line BIP-340 signer on `pointycastle` secp256k1, validated by the official vectors (signing only; relays verify, our AEAD authenticates).

### 7.4 Risks

| Risk | Mitigation |
|---|---|
| Public relays disappear, whitelist kinds, add payment or PoW | N >= 3 relays with health selection; kind 30078; user list + signed refresh list; ntfy backup; self-host recipe (strfry Docker, or Cloudflare Worker for power users); manual link flow always works. Observed churn already (section 2.2) |
| Relay operators dislike traffic | Low rate caps, one replaceable event per slot (no storage growth), NIP-40 expiry on every event, no PoW evasion; stop on `blocked:` |
| User expectation of AirDrop-grade reliability | UI says "Online / Last seen 12 min ago"; offers show "waiting"; docs state best effort |
| Android sleeps | Presence only in Receive mode window/foreground; catch-up on resume; no FCM |
| Sender cannot host a tunnel (Android, no cloudflared, CGNAT upstream) | Android-as-sender stays unsupported (spec s7.4) until portmap/Rust tunnel; UI explains |
| UPnP security surface | Per-transfer mapping, token-gated E2E origin only, never the API server, default OFF, lease <= 1 h |
| secp256k1/BIP-340 own implementation bugs | Official test vectors in CI; a bad signature is detectable as relay `invalid:` in the live probe |
| Metadata linkage (IP + pair) | Documented; optional SOCKS5/Tor setting is an open question |

### 7.5 Open questions for the user (real decisions)

1. **Is "free public Nostr relays, best effort, no SLA, plus an ntfy backup and documented self-hosting" acceptable as the meaning of "free"?** If not, the only alternative that satisfies $0 is dropping cross-network presence and keeping today's manual tunnel link/QR flow.
2. **Schedule:** add Increment 6 and move polish/packaging to a Sprint 7, or keep six sprints and trim polish and stretch items?
3. **Port mapping (UPnP/NAT-PMP/PCP):** ship in 6b default OFF (recommended, opt-in per Settings), default ON for outgoing offers, or skip entirely?
4. **Privacy of relay metadata:** accept that relays see IPs and timing (recommended for v1), or require an optional SOCKS5/Tor setting in Inc 6?
5. **Pairing model:** pairwise QR (recommended: simple, revocable per pair) versus a "my devices" group secret (one scan per new device, weaker revocation); and confirm that rendezvous offers never auto-accept even from trusted devices in v1.

## Sources (all fetched 2026-11-03 unless noted)

- [S1] https://raw.githubusercontent.com/nostr-protocol/nips/master/01.md (kinds, filters, BIP-340)  [S2] .../master/README.md (kind registry, 30078 NIP-78) and .../11.md (relay limits)
- [S3] https://raw.githubusercontent.com/nostr-protocol/nips/master/40.md (expiration)
- [S4] https://www.mqtt-dashboard.com/ (HiveMQ public broker, redirect from broker.hivemq.com)  [S5] https://test.mosquitto.org/  [S6] https://www.emqx.com/en/mqtt/public-mqtt5-broker  [S7] https://pub.dev/packages/mqtt_client
- [S8] https://raw.githubusercontent.com/bittorrent/bittorrent.org/master/beps/bep_0044.rst  [S9] https://raw.githubusercontent.com/pubky/pkarr/main/README.md
- [S10] https://pub.dev/packages/dart_libp2p  [S11] https://developers.cloudflare.com/realtime/turn/  [S12] https://pub.dev/packages/webrtc_dart
- [S13] https://docs.ntfy.sh/publish/ (topic as password)  [S14] https://raw.githubusercontent.com/binwiederhier/ntfy/main/docs/publish.md ("Limitations")  [S15] https://docs.ntfy.sh/config/  [S16] https://docs.ntfy.sh/privacy/
- [S17] https://docs.github.com/en/site-policy/github-terms/github-terms-of-service (Section H, B.3)
- [S18] https://developers.cloudflare.com/durable-objects/platform/pricing/  [S19] https://developers.cloudflare.com/workers/platform/pricing/
- [S20] Firebase Spark and Supabase pausing: web search results (https://firebase.google.com/docs/database/usage/limits, https://supabase.com/kb/faqs/platform/free-project-pausing); Firebase page notes pricing "takes effect September 1, 2026": verify before relying
- [S21] https://tailscale.com/kb/1251/pricing-faq  [S22] ZeroTier/NetBird: secondary aggregators (costbench.com, agentdeals.dev) via web search: UNVERIFIED vs vendor pages
- [S23] https://libera.chat/policies/
- [S24] https://arxiv.org/html/2510.27500v1 (Trautwein et al., "Challenging Tribal Knowledge")  [S25] https://arxiv.org/pdf/2604.12484 (IMC '26 version; abstract not extractable, figures taken from S24 and the search snippet)
- [S26] https://ar5iv.labs.arxiv.org/html/1605.05606 (Richter et al., IMC 2016)
- [S27] https://pub.dev/packages/port_forwarder (via search result)  [S28] https://pub.dev/packages/bip340
- [S29] design 01, `docs/design/01-autostart-receive-mode.md`  [S30] https://developer.android.com/training/monitoring-device-state/doze-standby
- [P] My probes (NIP-11 GETs, anonymous Nostr publish/subscribe, STUN Binding Requests, pkarr relay GET), 2026-11-03, scripts in the session scratchpad (not committed). Dart SDK 3.13.7 `lib/io/socket.dart` read locally for `sourcePort`/`shared`.
