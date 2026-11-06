# Increment 4 - Reliable and fast: resume, connection ladder, hashing speed (Sprint 4)

Status: **PLAN, REFINED FOR EXECUTION BY THE LEAD (user decision 2026-11-06: Gemini does Inc 4 first, then Inc 5); see section 13. Nothing of it is in the real tree yet.** Written by the orchestrator, 2026-11-06 ~03:27 (real `date`). No code, no tests and no builds were run for this document except the read-only greps listed in section 0.
Sources: spec section 6 (ladder), section 4/8 (resume), section 12 Increment 4, section 13 (test strategy); `docs/adr/0002-connection-ladder-as-candidates.md`; `docs/roadmap.md` (NFR-02 risk); `docs/plans/post-mvp-plan.md` Wave 3 (I4.1-I4.4); `docs/plans/inc2-followups.md` (#7 idle timeout); `docs/plans/inc3.md` section 12 (hand-over to Inc 4); `docs/test-reports/inc2-docker.md` (AOT 31 MB/s); `docs/traceability.md` (FR-12, FR-13, FR-15, NFR-02, NFR-03); code under `packages/libreshare_core/lib/src` as of today.
Evidence tags: **UNVERIFIED** = not confirmed by a source I read or a run; each one has a spike or a test that settles it. Cost rule: everything is $0 for users and maintainers. Effort numbers are ESTIMATES (person-days, one human; agent-run differs).

## 0. Findings that change the plan (read first)

Verified by `ls`/`grep` on 2026-11-06:

1. **Nothing of the ladder exists.** `lib/src/connection/`, `lib/src/monitor/` and `lib/src/session/` are empty directories. There is no `Candidate` model, no `ConnectionManager`, no `StatusMonitor`. The only "Candidate" in `lib/` is a comment in `discovery/subnet_scanner.dart:366`. `FaultyTcpProxy` appears only in docs (spec, ADR 0002, inc1.md, traceability), not in any code.
2. **Resume is half there.** Present: `transfer/resume_store.dart` (sidecar `<name>.lspart.json`, bitmap persisted every 8 chunks, only claims synced chunks, 24 h window, validated against size/chunkSize/sha256/modified), `GET /sessions/{sid}/files/{fid}/state` (`api_server.dart:105`, `ApiClient.fileState`), and the sender already re-reads `/state` when a peer lost chunks (`file_sender.dart:569`). **Missing:** the D2 `SessionStore` (`storage/` has only `credential_store`, `device_registry`, `file_secret_store`, `receive_settings_store`), so the receiver's session table (`file_receiver.dart:168`, `_sessions` map) lives only in memory: after a receiver restart the sender gets 404 for its session id and must start a new session that adopts the sidecars. Whether the existing sidecar adoption works across a restart end to end is **UNVERIFIED** (Spike S4-B settles it before any design is fixed).
3. **No receiver idle timeout** (inc2 follow-up 7, `inc3-p4-tests.md` defect 7): only `sessionTtl` (24 h, lazy eviction). A dead sender keeps its names reserved until the next call evicts the session.
4. **The speed claim is a hypothesis.** Measured: loopback 100 MiB CLI plaintext **19.0-19.1 MiB/s** (JIT, 2026-11-06 00:13), AOT **29.4-29.6 MiB/s = ~31 MB/s** (Docker, `inc2-docker.md`), 5 GiB in-process 32.3 MiB/s. The target in spec/NFR-02 is 300 MB/s loopback and 100 MB/s Docker bridge, about 10x away. "Pure-Dart SHA-256 is the cause" was never profiled (`inc2-docker.md` says so). What the code does today: the sender hashes each chunk in an `Isolate.run` when the chunk is > 256 KiB (`hashing.dart`, `sha256OfChunk`), plus a whole-file hash in another isolate when the manifest has `sha256: null` (`file_sender.dart:500`); the receiver hashes each chunk while writing (`file_receiver.dart:697`) and the whole file again in `Isolate.run` at finalize (`file_receiver.dart:841`). That is about 4 SHA-256 passes per byte for a large file (2 per side) plus TLS (native BoringSSL, fast) and the HTTP stack. **Not profiled: all of this.** The first deliverable is a profile, not a fix.
5. **TLS is now in the data path** (Inc 3). Every number above except the "secure smoke" planned in `INC3_CLOSURE_PLAN.md` G1 was measured on the plaintext profile. Inc 4 targets must be measured on the secure profile, and the cost of TLS is part of the profile.
6. **The Docker stack has one network** (`lan_net`, 172.28.5.0/24; `tools/docker/compose.yaml`) and `tools/bench/` and `tools/netem/` are empty. `tc netem` needs `NET_ADMIN`, which the tester container already has. The spec's `bench_lan.sh` file name does not exist yet.
7. **Security carry-overs the ladder must respect** (`inc3.md` section 12, hand-over): the candidate hook must carry the **pinned fingerprint** (a fallback tier must never connect to a different key than the one that was authenticated), the `ApiClient` pin API is reused, SAS/TOFU are not repeated on a tier switch (the session is already authenticated), and a switch must not re-open the PIN guard budget or the per-IP limits.

## 1. Scope

**In scope (spec section 12 Increment 4 + roadmap + follow-ups):**
- I4.1 profile, then speed up the hashing/transfer path (NFR-02), with a bench script and a regression gate.
- I4.2 resume: D2 `SessionStore`, receiver restart resume (FR-15), receiver idle timeout (follow-up 7), clean `FAILED` with persisted state (NFR-03).
- I4.3 connection ladder: `Candidate` model (extensible, carries the pin), `ConnectionManager`, Wi-Fi and LAN tiers, `fallbackToNext` + resync via `/state` (FR-12, FR-13), `FaultyTcpProxy`, Docker `wifi_net` + `lan_net` with `tc netem`.
- I4.4 `StatusMonitor` + D4 `EventLog`, channel badge (Wi-Fi / LAN / Internet), History screen.
- LSP/1.2-or-1.1.x additions only if a spike proves they are needed (section 3); then LSP-1.md + schemas + conformance move together (CLAUDE.md rule).

**Explicit non-goals:** tunnel tier and `TunnelConnection` (Inc 5; the ladder must have the slot, `ladder[2]` unavailable until Inc 5), `tunnelOffer`, rendezvous (Inc 6), BLE/hotspot candidate sources (Inc 7; the `Candidate` kind field must leave room), Windows packaging, signed builds, any paid service, a Rust/native core rewrite (NFR-08 stretch). Folders are NFR-08, not here.

## 2. Decisions to settle before coding

### D1 What "done" means for NFR-02 (USER DECISION needed, see section 11)

The spec target (300 MB/s loopback, 100 MB/s Docker bridge) is very likely **out of reach in pure Dart with 4 SHA-256 passes per byte**: even a hypothetical 150 MB/s pure-Dart SHA-256 gives under 40 MB/s with four passes serialized, and the realistic gain from parallel isolates is bounded by cores. Options, cheapest first (all free):
- **A. Reduce and parallelize the work, stay pure Dart.** Hash on an isolate pool; compute the whole-file hash incrementally in chunk order while chunks arrive (no second read of the file); sender hashes while reading (one read pass); overlap disk and network I/O. Expected: a multiple of today's rate (the first gate below is >= 2x), not 10x. **UNVERIFIED** until profiled.
- **B. Native hashing in the app layer only** (`package:cryptography_flutter`, Apache-2.0; platform support for Linux and Windows UNVERIFIED, may fall back to Dart there). The CLI/core stay pure Dart.
- **C. Change the integrity construction** (protocol change, LSP-1 + ADR): whole-file hash = hash over the list of chunk hashes (one pass per byte per side instead of two). Rejected for now: it changes a normative field (`sha256` in the manifest) and breaks interop with 1.0/1.1 peers; reconsider only if A and B miss the agreed target.
- **D. Re-baseline NFR-02** to the measured achievable number (an SRS amendment, like the decimal-MB change the user approved).
**Recommendation:** run S4-A (profile), do A, take the measured result, then ask the user to choose between D (honest re-baseline) and B (native path). Do not promise 300 MB/s.

### D2 Session persistence (D2 `SessionStore`)

- **Recommend:** `storage/session_store.dart` writing `sessions/<sid>.json` atomically (write temp + fsync + rename, mode 0600, like `FileSecretStore`); receiver-side record: session id, sender fingerprint, manifest hash, per-file name/size/chunkSize/sha256, state, `lastActivity`, `FailureReason`. It never stores PINs, tokens or key material (the token is re-derivable: a restarted receiver requires a **new** authenticated request; see D3). Sender-side record: peer id, chosen candidate id, file list with progress, so the app can show "interrupted - resume".
- Why not just rely on the sidecars: the sidecar knows the chunks, not who is allowed to continue them; a restarted receiver must not let an unauthenticated caller adopt a half-file.
- **Open (S4-B):** does a restarted receiver restore the session (same sid, sender re-authenticates and continues) or does the sender open a new session whose manifest matches the sidecars (adoption)? The second needs no new protocol field and is the **default**; the first needs a `409/410` semantics doc in LSP-1.

### D3 Resume across a restart under the secure profile

The restarted receiver must re-run the full security path for the continuing request: TLS, signed proof (replay cache is empty after restart: the timestamp window of the proof, not the cache, is what bounds replay; check D9 of inc3), PIN (a restart must not reset the **failure counters to give an attacker a fresh budget**: persist the block list and the global lock state, or document the loss as a known limit with a test), Contacts-only 404, consent (a trusted contact may auto-accept; everybody else sees the prompt again, with the SAS commit flow if needed). Tests: restart does not reduce the PIN guard's protection below the limits of inc3 D5 (or the known limit is stated).

### D4 Connection-loss classification and timing (from the spec; do not invent new numbers)

Connect per candidate 3 s, same-tier candidates raced, tier budget 8 s, TLS handshake 5 s, chunk idle 30 s on LAN, channel failed after 3 consecutive chunk failures or ECONNREFUSED/EHOSTUNREACH/ENETUNREACH or two failed `GET /info` in 4 s, give-up after 120 s with no tier healthy -> `FAILED(NO_CONNECTION)`, state kept 24 h, upgrade probe every 30 s while on tier >= 2 (stretch). These are constants in one file with tests for each boundary (injected `Clock`).

### D5 What a "tier" is in this increment

ADR 0002: tiers are paths, not radios. Tier 1 = addresses of the peer reachable through the interface classified as Wi-Fi, tier 2 = every other local address of the peer (Ethernet, second NIC, other subnet, manual/QR). **Classification of `if:"wifi"` is the weak point:** `NetworkInterface` has no reliable "is Wi-Fi" flag on every OS (name heuristics on Linux/Windows, `network_info_plus` on Android, **UNVERIFIED**; spike S4-C). Fallback: treat interface kind as a hint only, order candidates by (kind hint, last success, RTT), and never claim a Wi-Fi badge the OS did not confirm.

### D6 Pin continuity on every tier

A `Candidate` carries `(host, port, peerFingerprint)`; the connection is refused (and reported as `KEY_CHANGED`, never as a plain connection failure) if the certificate presented at a fallback address differs from the pinned/authenticated one. This is the Inc 4 half of the "candidate hook must carry the pin" hand-over. Test: a tier-2 address answered by a server with another key must not be used and must raise the key-changed event.

## 3. Protocol changes

Goal: none. The resume (`/state`, inclusive ranges, idempotent PUT) and the chunk semantics already exist in LSP-1. Candidate addresses are already in the announce (`addrs` with `if`). A change is allowed only with proof from a spike (for example a `410 Gone` for an expired session, a `Retry-After`, or an `X-LS-Resume` hint), and then: LSP-1.md + schemas + conformance tests + a new minor version note, all in one commit-sized unit, orchestrator-owned. If S4-B shows that session restore needs a field, it is written down as a proposal in `docs/plans/inc4-protocol-proposal.md` first and waits for the orchestrator.

## 4. Requirements trace and tests (names, not code; tests first)

| Req | Acceptance (all by real exit codes) | Test files (proposed names) |
|---|---|---|
| **FR-12** Wi-Fi tier first when healthy | with both tiers up, the first connection and every chunk use tier 1; ladder order is deterministic | `unit/ladder_order_test.dart`, `unit/candidate_test.dart` |
| **FR-13** fall back to LAN <= 10 s, no acked chunk re-sent | in-process: `FaultyTcpProxy` cuts tier 1 at 40 %; completes on tier 2; count of `PUT` per chunk index in the receiver log <= 1 (acked chunks) ; Docker: `docker exec` `tc qdisc add dev eth0 root netem loss 100%` on `wifi_net` at 40 % | `unit/fallback_test.dart`, `integration/ladder_fault_test.dart`, Docker step `m` in `e2e.sh` |
| **FR-15** receiver killed and restarted resumes from bitmap, up to 24 h | kill -9 the receiver at 40-60 %, restart, sender continues; the final file `cmp`-identical; the server log shows no `PUT` for an acked chunk; a sidecar older than 24 h is discarded | `unit/resume_after_crash_test.dart` (name fixed by traceability), `integration/receiver_restart_test.dart`, Docker kill/restart step |
| **NFR-02** | `tools/bench/bench_lan.sh` writes a CSV (date, commit-less label, profile plain/secure, MiB/s, CPU%) for loopback 1 GiB and Docker bridge; gate script fails on > 20 % regression against the committed baseline; first absolute gate **>= 2x the 19.0 MiB/s secure/plain baseline**, final number per D1 decision | `tools/bench/bench_lan.sh`, `tools/bench/gate.sh`, `unit/hash_pipeline_test.dart` (correctness of the new pipeline: golden digests, out-of-order, truncated, 0-byte, 4 MiB boundary) |
| **NFR-03** 20 randomized fault runs | `FaultyTcpProxy` with a seeded random schedule (cut, delay, truncate, reset, bit-flip); each of 20 seeds ends `COMPLETED` (byte-identical) or `FAILED` with a persisted, resumable state; seeds are printed so a failure replays | `integration/random_faults_test.dart` (tagged `slow`, run in the gate, 20 seeds) |
| Idle timeout (follow-up 7) | no chunk for 30 s (injected clock) -> session `FAILED(TIMEOUT)`, names released, partial kept for resume, `SessionFinished` event | `unit/receiver_idle_timeout_test.dart` |
| Pin continuity (D6) | wrong key at a fallback address -> refused, `PeerKeyChanged` | `security/ladder_pin_test.dart` |
| Restart vs PIN guard (D3) | after restart the block list/global lock is not weaker than before (or known limit asserted) | `security/restart_guard_test.dart` |
| I4.4 badge/History | channel events drive the badge text; History lists finished/failed sessions from D4 after restart | `app: channel_badge_test.dart`, `history_screen_test.dart` |

### 4.1 Negative tests (checklist the reviewer runs)

Truncated chunk after a cut (receiver must not mark it received); duplicate `PUT` after reconnect is idempotent; sender resumes against a receiver that lost the partial file (bitmap says yes, file says no -> `ResumeStore` discards); manifest changed between attempts (size/modified differ -> restart from 0, never resume into a different file); fallback address owned by another device (D6); tier-1 flapping (up/down every 2 s) causes no thrash (hysteresis test); `/state` answered with out-of-range or overlapping ranges (rejected); time going backwards (clock injected); disk full during resume (`INSUFFICIENT_STORAGE`, state kept); two senders resuming the same names; the PIN is never in an event, a log, a D2/D4 record.

## 5. Work breakdown (parallel subagents, strict file ownership; roles per CLAUDE.md)

### Wave 0 - orchestrator (about 1 d), before any package starts
Contracts only: `lib/src/connection/candidate.dart` (model: kind, host, port, peerFingerprint, source, cost hints), `connection/connection.dart` (interface), `monitor/channel_event.dart` (`ChannelActive`, `ChannelFailed`), `storage/session_store.dart` interface + record types, barrel exports, `docs/plans/inc4-seams.md`. Orchestrator-owned from then on (like `model/*`).

### Spikes (first, each 0.5-1 d, results in `docs/test-reports/inc4-spikes.md`)
- **S4-A profile** (no tree change; runs in a scratch clone, AOT and JIT, plain and secure): per-stage time and CPU for a 1 GiB loopback transfer: disk read, chunk hash (sender), TLS, HTTP framing, receive write, chunk hash (receiver), whole-file hash. Tooling: `dart compile exe`, `--observe`/DevTools CPU profile or a manual stopwatch harness, `perf` if available (**UNVERIFIED** on this box). Output: a table that names the dominant cost. **Decides D1.** Can run now, read-only.
- **S4-B restart behaviour:** kill the receiver mid-file in the current tree (two CLI processes, plain and secure); record what the sender sees (404? connection refused?), whether the sidecar is adopted by a second `send`, and what remains on disk. **Decides D2.** Can run now.
- **S4-C interface kind:** what `NetworkInterface.list()` and `network_info_plus` give on Linux (here), Android (emulator) and what Windows would give (documented, unverified): fields, names, `isLoopback`, `isLinkLocal`. **Decides D5.**
- **S4-D netem in Docker:** confirm `tc qdisc add dev eth0 root netem loss 100%` and `delay`/`rate` work inside the project's container on this host (the kernel module may be missing: UNVERIFIED). If not, `FaultyTcpProxy` carries the Docker steps via a proxy container.

### Wave 1a (parallel, 3-4 d): independent packages
- **P4-1 Bench + gate** (`tools/bench/**` only): `bench_lan.sh`, `gate.sh`, CSV format, baseline file. Coder low/medium.
- **P4-2 FaultyTcpProxy + test harness** (`packages/libreshare_core/test/helpers/faulty_tcp_proxy.dart` + its own tests): cut, delay, truncate after N bytes, reset, bit-flip, seeded random schedule; TCP-level so it works under TLS. Tester writes its own spec tests first (a test helper needs tests too).
- **P4-3 SessionStore + EventLog** (`storage/session_store.dart`, `storage/event_log.dart`): atomic writes, 0600, corrupt-file handling, TTL purge at 24 h, no secrets.

### Wave 1b (parallel, 4-5 d, after Wave 0 and S4-A/B)
- **P4-4 Hash/transfer pipeline** (`transfer/hashing.dart`, `file_sender.dart`, `file_receiver.dart`: **security-critical**, medium coder + second tester): the change chosen by D1 (A): isolate pool, in-order incremental whole-file hash, single read pass. Existing hash-mismatch tests (422, whole-file mismatch) must stay green unchanged; golden digests; memory stays constant (assert peak RSS on a 1 GiB run).
- **P4-5 Resume + idle timeout** (`file_receiver.dart` session restore/adoption, idle timer, `resume_store.dart` unchanged unless a bug is proved): security-critical, medium coder + second tester.

### Wave 2 (5 d)
- **P4-6 Connection layer** (`connection/*`): `Candidate` sources (peer `addrs`, manual), `WiFiConnection`/`LANConnection`, `ConnectionManager` (connect, race, `fallbackToNext`, resync via `/state`, give-up), pin continuity (D6). Security-critical (it decides which key to talk to): medium coder + second tester.
- **P4-7 Engine/CLI wiring** (`engine/*`, CLI flags `--candidate`, `--no-fallback` for tests): the engine uses the manager; new events; STATUS flag `INC4_P6_GATE` analogous to P6a (orchestrator-only).

### Wave 3 (parallel, 4-5 d)
- **P4-8 App**: channel badge, History screen, "interrupted - resume" action, a visible state while falling back (`apps/libreshare_app/lib/**`).
- **P4-9 Docker**: second network `wifi_net`, `cut_wifi.sh` (`tc netem`), steps m (cut at 40 % -> LAN), n (kill/restart receiver), o (20 seeded fault runs via the proxy container), p (bench on the bridge) in `tools/docker/**` only.

### Wave 4 - orchestrator close-out (1.5 d)
Definition of done below, traceability, `docs/plans/inc4.md` section 12 outcome, roadmap, CLAUDE.md map (connection 4.0, monitor 8.0 now exist).

### Definition of done, every package
As inc3.md (format, analyze `--fatal-infos`, new tests 3x green, `grep` no Flutter in core, one mutation check per area, no file outside the owner list changed, no `print`, no secrets in logs) plus: heavy runs via `flock -o /tmp/libreshare-heavy.lock`, `TMPDIR` set to `REPO/.toolchain/tmp`, runs alone.

## 6. Effort (ESTIMATE, person-days, one human; the post-mvp plan said about 22 pd for Inc 4 as a whole, this breakdown sums to a bit more)

| Item | pd | Confidence |
|---|---|---|
| Spikes S4-A..D | 3 | medium |
| Wave 0 contracts | 1 | high |
| P4-1 bench/gate | 2 | medium |
| P4-2 FaultyTcpProxy | 3 | medium |
| P4-3 SessionStore + EventLog | 3 | high |
| P4-4 hash pipeline | 5 | **low** (depends on the profile) |
| P4-5 resume + idle timeout | 5 | medium |
| P4-6 connection layer | 7 | medium-low |
| P4-7 engine/CLI wiring | 3 | medium |
| P4-8 app | 4 | medium |
| P4-9 Docker | 4 | medium (netem availability) |
| Wave 4 close-out | 1.5 | high |
| **Total** | **~41** | low-medium |

## 7. Risks and unknowns

1. **The 300 MB/s target is probably unreachable in pure Dart** (D1). Mitigation: S4-A first, a user decision with a measured number, no promise in docs.
2. `tc netem` / `NET_ADMIN` may not work in this container's kernel (S4-D); mitigation: the proxy container.
3. Interface classification (Wi-Fi vs other) is unreliable across OSes (D5); mitigation: hints only, honest badge.
4. Restart-resume may require session restore (protocol change) instead of adoption (S4-B).
5. A restart can hand an attacker a fresh PIN-guard budget (D3).
6. Real Wi-Fi roaming, AP isolation, real phones: only on hardware (not closable here).
7. Time-based tests are flaky if they use the wall clock; every timeout test uses the injected `Clock` and a 60 s test timeout.
8. Windows `FileMode.append`+`setPosition` for the `.lspart` file is still unverified on Windows.

## 8. Free-tooling check

Docker, `tc`/`netem` (kernel), `dart compile exe`, `perf` (if installed), DevTools: all free. `cryptography_flutter` (Apache-2.0) only if D1 option B is chosen; check the licence entry in `docs/dev/licences.md` and platform support at that time. No paid service, account, or signing key is needed.

## 9. Criteria for declaring Inc 4 done (all by real exit codes; alone; `flock -o`)

```bash
source tools/env.sh
dart pub get;                                                       echo "pub=$?"       # 0
dart format --output=none --set-exit-if-changed .;                  echo "format=$?"    # 0
dart analyze --fatal-infos;                                         echo "analyze=$?"   # 0
(cd packages/libreshare_core && dart test -j 1);                    echo "core=$?"      # 0, incl. new tests, 3x green for the new files
(cd packages/libreshare_cli  && dart test -j 1);                    echo "cli=$?"       # 0
(cd apps/libreshare_app      && flutter test --concurrency=2);      echo "app=$?"       # 0
grep -RnE "package:flutter|dart:ui" packages/libreshare_core/lib;   echo "grep=$?"      # 1
bash tools/bench/bench_lan.sh;                                      echo "bench=$?"     # 0, CSV written
bash tools/bench/gate.sh;                                           echo "gate=$?"      # 0 (>= 2x baseline first, final number per D1; <= 20 % regression)
docker compose -f tools/docker/compose.yaml up --build --abort-on-container-exit --exit-code-from tester; echo "e2e=$?"  # 0, steps a..p PASS
tools/package_prototype.sh linux android;                           echo "package=$?"   # 0; sha256sum -c rc 0
tools/android_emulator_smoke.sh;                                    echo "smoke_android=$?"  # 0, 18 checks + the new badge check
```
plus: M-mutations for Inc 4 (list in the section-12 draft: ladder tries tier 2 first; acked chunk re-sent after switch; resume ignores a size mismatch; idle timer never fires; pin check skipped on fallback; hash pipeline skips the whole-file check) each turn a named test red; the 20 seeded fault runs are green and the seeds are in the report; `inc4-spikes.md` has the profile table; the user has chosen D1.

## 10. Out-of-scope findings this increment touches

Known limits carried from Inc 3 that Wave 1b/2 will touch and should fix or restate: `FileReceiver.getSession` held polls for IN_PROGRESS (card C1), the receiver connection cap (post-MVP plan R1), Contacts-only greeting is one-shot (R4), legacy-plaintext device-list send ends as `noConnection` (defect C of d1-fixes; the candidate model in Inc 4 can make it return the "older version" message because a plaintext candidate can be probed explicitly).

## 11. Questions for the user (only genuine decisions)

1. **NFR-02 target (D1).** After the profile: re-baseline NFR-02 to the measured number (recommended if the profile shows hashing in pure Dart is the wall), or accept a native hashing path in the app only? Needed at the end of Wave 1b, not now.
2. **Windows route** (carried from the post-MVP plan): GitHub Actions on a pushed repo, or your own Windows PC? Needed before any Windows claim for the ladder (interface classification on Windows is unknown).
3. Is a restart-survives-PIN-guard guarantee required (D3), or is a stated known limit acceptable for this increment?

## 12. Outcome / deviations

Not started. To be filled by the orchestrator at close-out, in the style of `inc3.md` section 12 (done-and-proven with commands and counts, bugs found and fixed, mutation map, known limits, hand-over to Inc 5: the `ladder[2]` slot, `tunnelOffer`, `Candidate.kind`).

## 13. Refinement for execution by the Lead (2026-11-06 14:38:13 by `date`, orchestrator)

**13.1 Who does what.** The Lead (Gemini) runs the cards with its own tester/coder/verifier subagents (prompt: `docs/plans/MODULE_I_PROMPT.md`), strictly patch-only in scratch clones. The orchestrator owns the contracts (Wave 0), re-runs every card alone, applies it to the real tree (snapshot first), runs the section-9 gate after each phase, and does the close-out. The orchestrator spawns no new subagents of its own from now on (user decision); the R-series (E5) second-tester stage is held back by the user, the independent verifier stage is kept.

**13.2 Defaults for the open questions** (the user may overturn any of them; none is irreversible; they exist so the Lead is never blocked):
- **Q1 NFR-02:** the gate is "at least 2x the loopback baseline" first (plain about 36 MiB/s from 18 MiB/s), then the best number the profile shows is achievable in pure Dart with isolates; the final target is re-baselined to that measured number in section 12. No native hashing path in this increment.
- **Q2 Windows route:** no Windows claim for the ladder in Inc 4; interface classification on Windows stays UNVERIFIED and is listed as such.
- **Q3 PIN counters across restart:** known limit, documented (user guide + known limits); seams invariant 3 not adopted.

**13.3 What already exists and how it enters.**
| Item | State | Entry |
|---|---|---|
| `faulty_tcp_proxy.dart` + 12 tests, `tools/bench/*` (P4-2, P4-1) | in the real tree, gate-green, never reviewed by the chain | card A1 (verifier-only audit with a mutation table) |
| Wave 0 drafts (`inc4-proposals/wave0/`) | drafts, 27 tests under docs/, contract errors found (see `inc4-seams.md` corrections) | the orchestrator corrects, tests and applies them (`INC4_WAVE0: APPLIED`) |
| P4-3 event log draft, P4-5 idle-timeout draft | drafts under `inc4-proposals/` | inputs for B1/B2; a tester writes the real tests first |
| S4-A claim (pure-Dart SHA-256 = 83.1 % of the pipeline) | arithmetic consistent, harness not re-run by the orchestrator | re-run in card A2, the orchestrator re-measures before D1 is fixed |

**13.4 Order and dependencies.** Phase A (no Wave 0 needed): A1 audit, A2 spikes S4-A..D, A3 P4-4 hash/transfer pipeline. Phase B (after `INC4_WAVE0: APPLIED`): B1 P4-3 SessionStore + EventLog, B2 P4-5 resume + idle timeout. Phase C: C1 P4-6 connection layer, C2 P4-7 engine/CLI wiring. Phase D (parallel): D1 P4-8 app, D2 P4-9 Docker. Security-critical cards (P4-4, P4-5, P4-6) get a second tester inside the Lead's chain.

**13.5 Apply cycle.** Card done = folder `docs/plans/inc4-proposals/<card>/` complete + `READY <card>` in `overnight-log.md`. Orchestrator: fresh copy, patch, the card's tests 3x, relevant suites, then apply with a snapshot, then `APPLIED <card>` in STATUS.md. A phase ends with the full section-9 gate (the parts that apply so far). Cards that do not depend on each other may be READY in any order.

**13.6 Capacity and time.** The Lead uses at most 3 subagents (4 after `E5_WAVE_DRAINED: YES`); all heavy runs share ONE lock, so wall-clock time is bounded by that lock and by the orchestrator's apply cycle, not by the number of agents. No calendar estimate is given.

