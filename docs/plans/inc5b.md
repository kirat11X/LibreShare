# Increment 5b - Direct internet paths: IPv6 candidates, UPnP / NAT-PMP / PCP port mapping, "Hide my IP"

Status: **PLAN ONLY. Not started. Starts after Increment 5 is accepted (`INC5_DONE: YES`).** Written by the orchestrator, 2026-11-06 20:54:54 (real `date`). No code, tests or builds were run for this document.
Sources: `docs/design/04-link-qr-and-free-internet-paths.md` (tiers A/B, section 5.1-5.4, S23-S27 notes), `docs/design/02-free-rendezvous.md` section 3.7 (port mapping as a `TunnelProvider`), `docs/roadmap.md` (5b committed by the user 2026-11-03), `docs/plans/inc5.md`.
Evidence tags: **UNVERIFIED** = not confirmed by a source I read or a run in this container. Estimates are person-days for one human, not measured for agents.

## 0. Findings that shape the plan
1. **Ownership conflict resolved.** Design 02 puts UPnP/NAT-PMP/PCP into Inc 6 stretch "6.7"; design 04 and the roadmap put it here. Decision: **`nat/` lives in 5b only**; Inc 6 consumes it (a `PortMapTunnelProvider` entry in the provider list). Inc 6 step 6.7 loses its port-map item.
2. **Nothing of 5b can be proven on a real router from this container** (no router, no internet radio). Everything runs against fakes and a Docker `gateway` container; the real-router result is a manual matrix row (R-NAT), so 5b is "done except live" unless the user runs it.
3. Inc 5 must already leave the seams: `OriginCandidate{kind,base,tlsPinHex}`, `candidate_race.dart`, link params `d` and `pin` parsed and ignored (inc5.md D2). 5b only turns them on. If Inc 5 lands without them, 5b starts with a Wave 0 seam patch (orchestrator).
4. Firewall: direct origins use their own port range 53330-53349 (inc5.md section 0 item 7). Installer rules and `docs/user/guide.md` change here, not in Inc 5.

## 1. Scope
**In:** `nat/` module (`ip_classify`, `ssdp`, `upnp_igd`, `nat_pmp`, `pcp`, `gateway_discovery`, `stun_client`, `port_mapper`, `reachability_probe`); IPv6 global-address candidates (carried in link param `d`, raced like any other); ephemeral-TLS direct origin (self-signed per share, SHA-256 pin in link param `pin`; the receiver pins, no CA); `DirectConnection`; staggered candidate race (IPv6 > mapped IPv4 > Cloudflare > zrok > manual, 250 ms stagger, <= 3 s per dead tier); disclosure line and **"Hide my IP address"** toggle (forces tunnel-only); installer/firewall range; Docker `gateway` e2e.
**Out:** IPv6 pinhole requests via IGDv2/PCP (5c), WebCrypto browser receiver (5c), bore/ssh providers (5c), hole punching (ADR 0003, Inc 6), Android as tunnel host.

## 2. Decisions (defaults flagged; the user may overturn)
| # | Decision | Default |
|---|---|---|
| D1 | Port mapping default | **OFF** in Settings until a recorded live mapping exists (design 02 recommendation). Per-share mapping only, lease <= 1 h, unmap on share end, `sweepStale()` at startup removes `LibreShare:<deviceId>` leftovers. |
| D2 | CGNAT gate | Use a mapping only if STUN reflexive IPv4 equals the gateway-reported external IP; otherwise skip the tier (design 02 3.7). |
| D3 | Own client, no `port_forwarder` | Own thin client behind `PortMapper` (~400 LOC): the 1.0.0 package is new, lists no Android and fails the current `xml` constraint (design 02 S27, **UNVERIFIED** today: re-check with `dart pub outdated`). XML parsing: own minimal parser or `xml` only if already resolved; **no new dependency without the orchestrator editing `pubspec.yaml`**. |
| D4 | SSRF/hostile gateway | `LOCATION` must be an RFC 1918 / link-local address on the same interface as the gateway; no redirects; XML <= 64 KiB; no DTD; SOAP calls only to that origin. |
| D5 | IP disclosure | One line in the Create-link sheet; "Hide my IP" is per share, default off for paired devices, **on** when the receiver is a stranger link (design 02 roadmap default 5). |
| D6 | Android | Receiver and direct host on Wi-Fi only; SSDP needs the `MulticastLock`; no cellular (CGNAT). |

## 3. Protocol changes (orchestrator-owned, together: LSP-1.md + schemas + conformance vectors)
- Share link: `d` (candidate list, max 4, each `kind:host:port`) and `pin` (SHA-256 hex of the ephemeral cert) become **honoured**; bounds and host rules from `inc5-seams.md` apply to every `d` entry (public routable only, no loopback, no private ranges except in tests with an injected policy).
- `tunnel-offer.schema.json`: optional `candidates[]` becomes consumed; `provider` open string gains `portmap`.
- LSP-1.md section 4.5: direct origin = same routes as the tunnel origin over TLS with the pinned cert; token and sealed-body rules unchanged (crypto does not depend on the transport).

## 4. Waves (every package: tester red -> coder green -> different verifier -> orchestrator gate; **security-critical = `ssdp`/`upnp_igd` parsing, `ip_classify`, ephemeral TLS pinning: second tester**)
| Wave | Content | Gate |
|---|---|---|
| 0 (orchestrator) | contracts: `PortMapper`, `GatewayInfo`, `PortMapping`, `ReachabilityProbe`, `OriginKind`, link `d`/`pin` seams, `inc5b-seams.md` | contract tests compile; `INC5B_WAVE0: APPLIED` |
| 1 | `ip_classify` (pure, table-driven: private/CGNAT 100.64/10/link-local/ULA/global/mapped-v4), `stun_client`, `reachability_probe` | unit + fuzz |
| 2 | `FakeIgdGateway`, `FakePcpServer`/NAT-PMP fake first (tests), then `ssdp`, `upnp_igd`, `nat_pmp`, `pcp`, `port_mapper` | fake-gateway cases: success, 718 conflict -> next port, 725 permanent-only, 606/501, hostile `LOCATION`, oversize/DTD XML, slow gateway, leak check (every mapping removed on every exit path) |
| 3 | ephemeral-TLS direct origin, `DirectConnection`, `candidate_race`, link `d`/`pin` | pin mismatch refused; stale candidate costs <= 3 s; race order test with fake clock |
| 4 | app/CLI: toggle, disclosure, "Hide my IP", Settings port-map switch; installer + guide | widget tests; `grep` that no screen logs a candidate list |
| 5 | Docker: `gateway` container (iptables MASQUERADE + miniupnpd, **UNVERIFIED** packaging in the base image) between `lan_net` and `inet_net` | e2e mutation-checked (the E1 lesson: every assertion must be able to fail) |

## 5. Tests (names, not code)
`ip_classify_test`, `stun_client_test`, `upnp_igd_test` (+ `igd_hostile_test`), `nat_pmp_test`, `pcp_test`, `port_mapper_leak_test`, `direct_origin_pin_test`, `candidate_race_test`, `hide_my_ip_test`, `link_d_pin_conformance_test`; Docker step `q)` direct transfer through the gateway container; live (manual, `LS_NAT_LIVE=1`) one recorded mapping on a real router in `docs/test-reports/inc5b-live.md`.

## 6. Effort (estimates)
about 14 person-days (design 04) + about 2 orchestrator (seams, protocol, close-out) = **~16**. Agent time is dominated by fake-gateway tests and the heavy lock.

## 7. Risks
UPnP/PCP success on target routers is unmeasured (**UNVERIFIED**); UPnP is a known attack surface (hence D1/D4, default OFF); IPv6 global address is not reachability (CPE default-deny, RFC 6092); Docker miniupnpd packaging may fail (fallback: fake IGD in-process only, Docker step marked skipped with reason); STUN servers are public third parties (use 2-3, user-editable, no account, **free**).

## 8. Free-tooling check
No paid service. Public STUN servers (free, best effort) and the router's own UPnP/PCP. No account or key. `miniupnpd` is GPL/BSD-style FOSS used only in a test container.

## 9. Done criteria (all by real exit codes, alone under the heavy lock)
analyze + format rc 0; no-Flutter-imports grep rc 1; suites >= Inc 5 closing counts + new tests, new files 3x green; mutation table (guard removed -> named test red) for `ip_classify`, hostile-LOCATION checks, pin check, unmap-on-exit; Docker step green and mutation-checked; Hide-my-IP test proves no direct candidate leaves the process; docs updated; `INC5B_DONE: YES` (or "done except live").

## 10. Questions for the user
1. Port mapping default OFF until a live mapping is recorded (recommended) vs ON for outgoing links?
2. Is a recorded real-router run available (home router, UPnP on)? Without it 5b stays "done except live".
3. STUN: accept public STUN servers (IP seen by the operator) or ship "no STUN, trust gateway-reported IP only" (weaker CGNAT check)?
