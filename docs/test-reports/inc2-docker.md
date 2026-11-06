# Increment 2 - Docker end-to-end test (spec 12 Inc 2 FR-02, spec 13/14)

Status: **passes**, three consecutive `tools/docker/run_local.sh` runs on the dev box (2026-11-03), 31 of 31 assertions each, 88-89 s per run including a cached image build. The same `docker compose ... up` command that CI runs (job `e2e-docker`) was also run directly once and passed.

## What runs

| | |
|---|---|
| Image | `libreshare-e2e/ls:local` (148 MB). Build stage `dart:3.13.7` (Debian 13, the exact Dart of `tools/env.sh`), runtime `debian:trixie-slim` + iproute2, iptables (nf_tables backend), procps, jq. |
| Binary | `dart compile exe packages/libreshare_cli/bin/ls.dart` (AOT), installed as `/usr/local/bin/libreshare` so it never shadows coreutils `ls`. |
| Workspace trim | The repo root is a pub workspace that lists `apps/libreshare_app` (needs Flutter, absent from the `dart` image). The Dockerfile copies only `packages/` and the root `pubspec.yaml`/`pubspec.lock`, and deletes every `apps/...` member line with `sed` before `dart pub get`. `tools/docker/Dockerfile.dockerignore` is an allow-list, so `apps/`, `.toolchain/`, `.git`, build dirs and docs never reach the daemon. |
| Network | one user-defined bridge `lan_net`, `172.28.5.0/24` (the scanner assumes a /24 per interface address). alice `.240`, bob `.250`, carol `.230`, tester `.10`. Receivers are at the **high end** of the /24 on purpose: the TCP sweep (64 workers, 800 ms per dead host) needs three timeout waves before it reaches them, so the 10 s bound is measured against a realistic worst case rather than a lucky first wave. |
| alice, bob | `libreshare receive --always --auto-accept --alias <name> --dir /data --port 53318` (non-root uid 10001). alice's `/data` is a named volume that the tester mounts read-only. |
| carol | Receive Off (a send-only `devices --listen` probe node), then `receive --for 12s` on a marker file in a shared `/sync` volume, then Off again. Lets the tester drive a Receive-Off scenario without a docker socket. |
| tester | root + `NET_ADMIN` only here (`iptables -A INPUT -p udp --dport 53318 -j DROP`, always removed by an `EXIT` trap). Runs `tools/docker/e2e.sh`. |

## How to run

```bash
tools/docker/run_local.sh                  # build (cached) + run + tear down, prints RESULT: PASS|FAIL; any cwd
BENCH_MIB=0 tools/docker/run_local.sh      # skip the 1 GiB AOT datapoint (about 35 s of the 88 s)

# what CI runs (spec 14); project name comes from `name: libreshare-e2e` in the file
docker compose -f tools/docker/compose.yaml up --build --abort-on-container-exit --exit-code-from tester
docker compose -f tools/docker/compose.yaml down -v --remove-orphans
```

Only the compose project `libreshare-e2e` is touched (image `libreshare-e2e/ls:local`, network `libreshare-e2e_lan_net`, volumes `libreshare-e2e_{alice_data,sync}`). `run_local.sh` tears down before and after; the image stays as a build cache (`docker rmi libreshare-e2e/ls:local` removes it). Note: always `down -v` between runs; `e2e.sh` refuses to start on stale `/sync` markers.

## Scenarios and results

Each time is wall-clock from just before the `libreshare devices --listen --json` process is started (so it includes process start-up and engine start) to the arrival of the FOUND line of the **last** wanted device. One un-measured warm-up discovery runs first. Three measured runs per scenario per test run; the table gives the worst of the three over the three test runs (all raw values are in the `METRICS` line the test prints).

| Scenario | Assertion | Measured (3 test runs, worst of 3 inner runs each) |
|---|---|---|
| a) FR-02 multicast | alice and bob found, last one <= 3 s; `source=multicast`; `devices --json --timeout 3` lists both with name, IP, platform linux, port 53318 (FR-03); carol (Off) absent | **10 / 11 / 10 ms** (individual runs 7-11 ms) |
| b) FR-02 fallback | with the DROP rule in place: control `devices` without `--scan` finds nothing and the rule counter is > 0 (9 packets in each run), then `devices --scan` finds alice and bob by `source=subnetScan` <= 10 s; rule removed and multicast works again | **2421 / 2425 / 2420 ms** (individual runs 2417-2425 ms); that is 3 x 800 ms timeout waves plus about 20 ms, so the sweep order matters: a receiver at `.11` would be found in milliseconds |
| c) discovery-driven transfer | `send --device alice` of a 20 MiB random file: exit 0, `COMPLETED`, `cmp` and SHA-256 identical in alice's volume, no `*.lspart*` left | 0.72 / 0.71 / 0.73 s = **27.6 / 28.3 / 27.5 MiB/s** |
| d) Receive-Off visibility | carol Off: not listed, `send --device carol` fails with "no device matching", nothing listens on TCP 53318; carol For 12 s: positive control (listed in 9-10 ms, TCP answers); carol Off again after the window: same three negative checks | passes; see "Gaps" |
| e) AOT loopback | 1 GiB file, two `libreshare` processes in one container (`/bench` is tmpfs), `cmp` identical | see below |

### AOT datapoint (NFR-02, first realistic number)

`libreshare send --to 127.0.0.1:53400` of a 1 GiB random file to a `libreshare receive --once --no-discovery` in the same container, AOT binary, tmpfs on both ends:

| test run | time | throughput |
|---|---|---|
| 1 | 34.89 s | 29.4 MiB/s = 30.8 MB/s |
| 2 | 35.28 s | 29.0 MiB/s = 30.4 MB/s |
| 3 | 34.58 s | 29.6 MiB/s = 31.0 MB/s |

**About 31 MB/s, roughly one tenth of the 300 MB/s NFR-02 target** (the JIT figure of Inc 1 was 19.2 MiB/s, so AOT is about 1.5x faster, nowhere near the target). The 20 MiB transfer over the real bridge runs at the same speed (28 MiB/s), so the network is not the limit: the process is CPU-bound, consistent with the roadmap's known risk that pure-Dart SHA-256 (per-chunk on both sides plus the whole-file hash) blocks NFR-02 until the Inc 4 hashing work. This run did not profile it; that attribution is a hypothesis.

## Gaps and notes found while building this

- **No goodbye datagram.** The Receive-Off check uses fresh `devices` processes. A list that was already running keeps a device that went Off for up to 90 s (known, `docs/plans/inc2.md`); the test prints a NOTE and does not assert it. There is also no CLI command that turns Receive Off while the process keeps running, so "Off" is expressed as "never received" (carol phase 1) and "window expired" (`receive --for`, the process exits).
- **`ls receive` prints no discovered peers**, so "two containers discover each other" (alice sees bob) cannot be asserted through the CLI; the test asserts that a third party (tester) discovers both, and that each is reachable.
- **Two sockets on UDP 53318 in one network namespace break discovery.** With `SO_REUSEPORT` the kernel spreads unicast replies between the two sockets, so a fresh `ls devices` starved while another `ls devices --listen` ran in the same container (found while writing scenario d; the test no longer runs two discovery processes at once in the tester). One host running two LibreShare processes will see the same effect; the replies are `announce:false` unicasts, so the multicast announcements still arrive every 30 s.
- The scan only probes the default port (known); alice and bob use 53318.
- The binary is installed as `libreshare`, not `ls` (it would shadow coreutils `ls` in the test scripts and in any debugging shell). Everything else follows the spec commands.
- Not covered here (by design): Wi-Fi Direct/hotspot, Windows, Android, `tc netem` (Inc 4).
