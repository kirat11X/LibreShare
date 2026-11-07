# Increment 6 - Free internet rendezvous and presence for paired devices (Nostr relays + ntfy backup)

Status: **PLAN ONLY. Not started. Starts after Inc 5 (and 5b's `nat/` seams, if 5b is done) are accepted.** Written by the orchestrator, 2026-11-06 20:54:54 (real `date`). No code, tests or builds were run for this document.
Sources: `docs/design/02-free-rendezvous.md` (the main source; verdict GO-WITH-CAVEATS; its relay probes are from 2026-11-03 and are stale), `docs/roadmap.md` (Inc 6 amendments, user decision "yeah lets try" 2026-11-03), `docs/plans/inc3.md` (pairing, trust store), `docs/plans/inc4.md` (Candidate / ConnectionManager), `docs/plans/inc5.md` (tunnel, `tunnelOffer`).
Evidence tags: **UNVERIFIED** = not confirmed by a source I read or a run. Estimates are person-days for one human, not measured for agents.

## 0. Findings that shape the plan
1. **Rendezvous is one more candidate source, not a new transport** (design 02 3.1): it feeds `Candidate`s and a `tunnelOffer` into the existing `ConnectionManager`. Inc 6 therefore needs the Inc 4 ladder (the Lead's code is in the tree but **not yet accepted**, STATUS.md `INC4_DONE: NO`) and the Inc 5 origin/tunnel pieces. Do not start before both are accepted.
2. **Pairing today is not enough.** Inc 3 pairs by QR with SAS but has only a nullable `K_pair` slot (`pairedAt` + nullable reference in D1/D3). Inc 6 adds the 256-bit `S` secret to the QR (`s=`), `K_pair` derivation and storage in D3 (`SecretStore`). On Windows the secret store route (DPAPI, module F5 proposal) is not applied: **Inc 6 on Windows is blocked until it is**; Linux/Android are not.
3. **BIP-340 (Schnorr over secp256k1) does not exist in the repo.** Plan: own ~80-line signer on `pointycastle` (`ECCurve_secp256k1` must exist there: **UNVERIFIED**, spike S6-A), validated by the official BIP-340 vectors. Signing only; relays verify, our AEAD authenticates. No new dependency.
4. **The relay landscape drifts.** Design 02's probes (NIP-11 + tiny events) are 3+ days old; relays churn. S6-B re-checks before any code. **Publishing events to public relays is outward-facing: it needs the user's explicit OK** (design 02 used at most 5 tiny anonymous expiring events per relay). Default for this plan: read-only NIP-11 GETs and WebSocket connect/REQ only; no EVENT until the user says yes.
5. **Nothing in Inc 6 can be proven "across the internet" inside this container.** All logic runs against `InMemoryRelay`, `LoopbackNostrRelay` (real sockets, in-process) and a Docker `relay` container; the live run is a manual row (`LS_RENDEZVOUS_LIVE=1`). Without it Inc 6 is "done except live".
6. **Rules that apply to everything here:** never log `S`, `K_pair`, derived seeds/keys, envelope plaintext, tunnel fragments or tokens (CLAUDE.md rule extended at Wave 0); an offer received over rendezvous **never auto-accepts** (R7).

## 1. Scope
**In:** `rendezvous/` module (`channel_deriver`, `envelope_codec`, `records` (presence, probe, offer, reply, revoke, pair-hello/accept), `bip340`, `nip01` event codec, `relay_backend` interface, `nostr_backend`, `in_memory_relay`, `presence_cache`, `rendezvous_service`, `rendezvous_candidate_source`); `PairingService` (S-secret QR, `K_boot`, SAS, `K_pair`, revoke); engine + `ReceiveGate` hook (`AnnouncePolicy.none` publishes nothing); offer flow with sealed accept/reject ack; CLI `ls pair --show | --scan <uri>`, `ls peers`; Flutter Pair screen, Paired devices list (Online / Last seen), "Internet" status chip, relay list setting; docs `LSP-R1.md`, ADR 0003, schemas, traceability FR-19..21, NFR-10, NFR-11.
**Stretch 6b (only after 6a is accepted):** `NtfyBackend` (low-rate), `tools/rendezvous_probe/`, `StunClient` reuse from 5b. **Port mapping is NOT here** (see inc5b.md section 0 item 1).
**Out:** discovering unpaired strangers over the internet (spam/enumeration, design 02 section 1); a project-run relay; hole punching (ADR 0003); FCM/Firebase (not $0-neutral); relayed data; group "my devices" secrets.

## 2. Decisions (defaults flagged; the user may overturn)
| # | Decision | Default |
|---|---|---|
| D1 | Meaning of "free" | Best-effort public Nostr relays, no SLA, user-editable list, self-host documented, manual link flow always works (roadmap default 1). |
| D2 | Pairing model | Pairwise QR with single-use 10-minute `S`, both sides confirm SAS, `S` erased after pairing (design 02 3.2). |
| D3 | Offers | Never auto-accept, even from trusted devices (v1). |
| D4 | Relay metadata | Accept that relays see IP/timing/sizes; disclosed in-app; optional SOCKS5/Tor = out of v1. |
| D5 | Hole punching | None (ADR 0003); `CandidateKind.reflexive` stays representable. |
| D6 | Android | Presence only while Receive mode window or UI is active; one catch-up REQ on resume; no FCM. |
| D7 | Crypto | HKDF (exists in `crypto_primitives.dart`), AES-256-GCM via the Inc 5 `tunnel_crypto` primitive (pointycastle), ECDSA identity signatures from Inc 3, own BIP-340. |
| D8 | Protocol | New `docs/protocol/LSP-R1.md` + schemas + conformance vectors; LSP-1 gets only additive items: `libreshare://pair` URI (4.2 item 6), sealed decision ack (4.5), optional `DeviceAddress.kind`, `caps: rdv1`. Breaking change found = STOP and ask. |

## 3. Spikes (read-only, before Wave 0; results in `docs/test-reports/inc6-spikes.md`)
S6-A `pointycastle` secp256k1 + BIP-340 official vectors + speed; S6-B relay re-probe (NIP-11 GET, WebSocket connect, REQ; **no EVENT without user OK**); S6-C `ntfy.sh` limits page and multi-topic `since` streaming (**UNVERIFIED** in design 02); S6-D Dart `WebSocket` behaviour against a loopback relay (ping/pong, close codes, backoff); S6-E what Inc 3 stores for `K_pair` today (code reading: D1/D3 fields, `s=` in the QR).

## 4. Waves (tester red -> coder green -> different verifier -> orchestrator gate; **security-critical, with a second tester: `channel_deriver`, `envelope_codec`, `bip340`, records signing/replay rules, `pairing_service`, offer validation**)
| Wave | Content (design 02 step) | Gate |
|---|---|---|
| 0 (orchestrator) | 6.0: `LSP-R1.md`, schemas, ADR 0003, interfaces (`RendezvousBackend`, `RendezvousService`, `PairingService`, record types), `inc6-seams.md`, CLAUDE.md map `rendezvous 9.0` + log rule + gotcha | schema conformance tests green; `INC6_WAVE0: APPLIED` |
| 1 | 6.1: `channel_deriver`, `envelope_codec`, records, signing, replay rules, `InMemoryRelay` | KAT/golden tests, epoch-edge and padding-bucket tests, tamper/wrong-key/wrong-AAD, `seq`/`issuedAt`/`ttl`/`offerId` with fake `Clock` |
| 2 | 6.2: `bip340`, `nip01` codec, `NostrBackend`, `LoopbackNostrRelay` | BIP-340 + NIP-01 id vectors; 3-relay failover (1 killed mid-run); hostile-relay fuzz (10k frames, max frame 128 KiB, <= 64 authors per REQ) |
| 3 | 6.3: `PairingService`, CLI pair/peers | wrong/expired/reused `S`; two scanners race (first Accept wins); tampered `sigB`; SAS equal; two CLI processes pair via a loopback relay |
| 4 | 6.4: presence, `PresenceCache`, `RendezvousCandidateSource`, engine + `ReceiveGate` hook | A sees B online <= 3 s; Receive Off publishes nothing; relay withhold/replay/forged tests |
| 5 | 6.5: offers, sealed decision ack, LSP-1 additions | two-engine internet test (LAN disabled, direct addresses unreachable, `FakeTunnelProvider`, 3 loopback relays, 5 MiB byte-identical, badge = Internet); Docker `relay` container, relay stopped mid-wait -> `RendezvousDegraded` then restored |
| 6 | 6.6: Flutter screens + Android lifecycle | widget tests; manual rows R-RDV (home router, campus, phone hotspot) |
| 7 (6b) | NtfyBackend, probe tool | fake-server tests; live probe recorded |

## 5. Requirements and tests
FR-19 pair by QR and see each other online across networks <= 10 s after start (two-engine test + live row); FR-20 send to a paired device on another network via tunnel offer with consent (two-engine + Docker); FR-21 unpair/revoke stops presence and offers both ways (`revoke_test`); NFR-10 $0 (CI grep: no paid-service host/dependency in `pubspec.yaml` or code); NFR-11 everything works with every backend down (`degrade_ladder_test`: LAN, QR, manual link unchanged).
Threat tests T1-T13 of design 02 section 4, by name: `envelope_opacity_test`, `channel_rotation_test`, `replay_test`, `forged_record_test`, `relay_withhold_test`, `foreign_author_test`, `offer_rate_limit_test`, `mitm_test` (extended), `tls_required_test`, `pairing_race_test`, `pairing_expiry_test`, `revoke_test`, `offer_always_prompts_test`, `signature_required_test`, `offer_validation_test`, `offer_fuzz_test`, `relay_failover_test`, `degrade_ladder_test`, `clock_skew_test`, `epoch_boundary_test`, `receive_off_publishes_nothing_test`. Log hygiene: a test that runs the whole flow with a capturing logger and asserts no secret value appears.
Property/fuzz: envelope and record parsers never throw past the boundary; no unbounded memory.

## 6. Effort (estimates)
Design 02: about 25 person-days for 6a (6.0 1.5, 6.1 3.5, 6.2 5, 6.3 3.5, 6.4 3, 6.5 3.5, 6.6 5) + about 9 for 6b (of which port mapping, about 4, moved to 5b, leaving ~5). Add ~4 orchestrator (seams, protocol, close-out, gates). **Planning figure ~29 (6a) + ~5 (6b).** Minimum viable cut: 6.0-6.5 with CLI only (~17-20) still demonstrates pairing, presence and offer in the Docker/CLI demo.

## 7. Risks
| Risk | Mitigation |
|---|---|
| Public relays vanish, add PoW/payment, whitelist kinds | >= 3 relays, health-based pick, user list + signed refresh list, ntfy backup, self-host recipe, manual flow always works |
| Own BIP-340 bug | official vectors in CI; second tester; live probe would show `invalid:` |
| Relay operators dislike traffic | token buckets (<= 20 EVENT/min/relay, presence <= 1 per 5 min per peer), NIP-40 expiry, stop on `blocked:` |
| Android sleeps / Doze | presence only in the window or foreground; catch-up REQ; documented |
| Sender cannot host a tunnel (Android, no cloudflared) | Android-as-sender stays unsupported; UI explains; 5b mapped/IPv6 helps on Wi-Fi |
| Windows secret store not applied | Inc 6 on Windows blocked; Linux/Android first |
| Over-claiming by the Lead (history) | every gate re-run by the orchestrator alone; tripwire in section 9 |

## 8. Free-tooling check
Nostr relays (public, free, no account), ntfy.sh free tier (limits **UNVERIFIED** today, S6-C), WebSocket from `dart:io`, no Firebase, no cloud account, no domain. Optional GitHub raw URL for a signed `relays.json` (free). All of it replaceable by user-run endpoints.

## 9. Process notes (apply to every wave)
- Roles per CLAUDE.md: orchestrator plans/owns contracts/gates/applies; testers (high) write tests first and show them red; coders (medium) make them green and may not touch tests; a different verifier (high) runs the mutation table; second tester on security-critical packages.
- **Patch-only delivery and a tripwire:** the Lead writes only to scratch clones and `docs/plans/inc6-proposals/<card>/`. The orchestrator records `git status --short` before each wave and diffs it after; any change under `packages/`, `apps/`, `tools/` (lib or test) that did not come from an orchestrator apply is a breach and rejects the wave (Inc 4 showed this is necessary). A test file may never change after its first red run without a listed diff and the user's OK.
- Heavy runs alone under `flock -o /tmp/libreshare-heavy.lock`; counts and rcs, never "passed".

## 10. Done criteria (real exit codes, alone)
1. analyze + format rc 0; no-Flutter-imports grep rc 1; secret-grep test green.
2. Core/CLI/app suites >= Inc 5 closing counts + new tests; every new file 3x green; no existing test edited.
3. Two-engine internet test, Docker relay scenario, `degrade_ladder_test`, pairing and threat tests green.
4. Mutation table for `channel_deriver`, `envelope_codec`, `bip340`, replay rules, pairing, offer validation: each removed guard turns a named test red.
5. Live probe (`LS_RENDEZVOUS_LIVE=1`) recorded in `docs/test-reports/inc6-live.md`, or Inc 6 is "done except live".
6. LSP-R1.md, schemas, vectors, traceability, user guide updated; `INC6_DONE: YES`.

## 11. Questions for the user
1. Is "best-effort public Nostr relays + ntfy backup + self-hosting" an acceptable meaning of "free"? (If not, Inc 6 shrinks to docs and the manual link flow stays.)
2. May S6-B publish up to 5 tiny expiring anonymous events per relay, or read-only only? (Default: read-only.)
3. Windows: when does the secret-store route (DPAPI, F5) get applied? Inc 6 on Windows waits for it.
4. Schedule: Inc 6 before Inc 7, or Inc 7 Phase A first? (Default: 6 then 7; Phase A of Inc 7 does not depend on Inc 6.)
5. Relay metadata: accept IP/timing exposure for v1 (default) or require an optional Tor/SOCKS5 setting?
