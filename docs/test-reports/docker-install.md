# Docker install (headless node) - test report

Date: 2026-11-04, dev box (Fedora, kernel 7.2, Docker Engine 29.8.2, Compose 5.6.0, SELinux enforcing, Wi-Fi `wlp0s20f3` 192.168.29.189/24). Subject: `deploy/docker/{Dockerfile,Dockerfile.dockerignore,entrypoint.sh,compose.linux.yaml,compose.windows.yaml}`, `deploy/install.sh`, `deploy/install.ps1`, `docs/dev/docker-install.md`.

**Verdict: (a)-(h) pass on Linux.** Not verified on this machine: `install.ps1` (never executed, never parsed: there is no `pwsh` here), anything on Windows/Docker Desktop (NAT behaviour is reasoned, not observed), macOS, `shellcheck` (not installed; pulling its image was refused by the sandbox, so only `bash -n`/`sh -n` ran). Details at the end.

All commands were run from the repository root with a unique compose project `libreshare-install-test`, port 53418 (so nothing collided with 53318), settings and data under the session scratchpad (never `deploy/docker/.env`), and every resource was removed afterwards. Other containers on the machine (`amex-*`) were never touched. Exit codes are the real ones (`RC name=code` lines of the test script's log; no pipe-masked codes except where `${PIPESTATUS[0]}` is used).

## Static checks

| Check | Command | Exit |
|---|---|---|
| Compose, Linux file | `docker compose -f deploy/docker/compose.linux.yaml config` | 0 |
| Compose, Windows file | `docker compose -f deploy/docker/compose.windows.yaml config` | 0 |
| Shell syntax | `bash -n deploy/install.sh`; `sh -n deploy/docker/entrypoint.sh` | 0; 0 |
| install.ps1 | `which pwsh` -> not found. **install.ps1 unexecuted and unparsed on this machine.** Only a crude Python scan (balanced `() [] {}`, closed quotes, no `else` after a line break) found nothing; file is ASCII-only, LF. | n/a |
| shellcheck | not installed; not run | n/a |

Bug found by reading `set -x` output while testing (not by a linter): `addr="${hostip:-<this machine's IP>}:$port"` - the apostrophe inside a double-quoted `${...:-...}` made bash swallow the next lines and the summary lost its first lines silently. Fixed; no apostrophes remain inside `${...}` defaults.

## (a) Build

`docker build --no-cache -f deploy/docker/Dockerfile -t libreshare/node:local .` -> **exit 0, 13 s** (base images already local; `pub get` and `dart compile exe` really ran because of `--no-cache`).

| | |
|---|---|
| Image | `libreshare/node:local` |
| `docker images` | 129 MB disk usage (containerd store accounting), **33.5 MB compressed content** |
| Layers | `debian:trixie-slim` 86.7 MB + AOT binary 8.72 MB + user/dirs 33 kB + entrypoint 8 kB = **about 95.5 MB** (the E2E test image, which also carries iproute2/iptables/jq, is 148 MB) |
| Runtime contents | no apt packages, no build tools, no compiler; only libc, `/bin/sh`, the binary and the entrypoint |
| Build context | allow-list `deploy/docker/Dockerfile.dockerignore` (pubspecs, `packages/` minus `test/`, `.dart_tool`, `build`, the entrypoint) |

CRLF check (Windows checkout with `core.autocrlf=true`): the entrypoint was temporarily converted to CRLF (114 CRs), the image built (exit 0): `docker run --rm IMAGE info --to 127.0.0.1:1` -> exit 1 (connection refused: the script ran) and `-e LS_PORT=abc` -> exit 64 with the message. The Dockerfile strips CRs. File restored to LF (0 CRs), test image removed.

## (b) Linux compose, host network

`docker compose -p libreshare-install-test --env-file b.env -f deploy/docker/compose.linux.yaml up -d --build` -> exit 0; healthy after 6 s; `NetworkMode=host`.

* `ls devices --timeout 5` (host-side AOT binary) -> exit 0: `DEVICE 16e20688-... dk-test-linux (linux) 192.168.29.189:53418 via=multicast`, `DEVICES 1` (multicast over the host network).
* `ls send --device dk-test-linux rand20.bin` (20 MiB, `/dev/urandom`) -> exit 0, `COMPLETED`, 28.6 MiB/s. `cmp rand20.bin data/rand20.bin` -> exit 0. The file is owned by the host user (container ran as `1000:1000`). The SELinux bind option `selinux: z` made the folder `container_file_t`; without a label the entrypoint's write probe fails with exit 73 and a message naming SELinux.
* Container log shows the exact warning block on stderr, then `LISTENING ...` / `PEER-LINK ...`.

## (c) `docker stop`, restart, state

* `docker stop` -> **exit 0 in 0.095 s**; `docker inspect` `ExitCode=0 OOMKilled=false` (SIGTERM reaches the binary through `exec` + `init: true`).
* A plain `docker run` without compose or `--init` (PID 1 = the binary): `docker stop` exit 0 in 0.20 s, `ExitCode=0`.
* `docker start` -> exit 0, healthy after 6 s. Received data survives (`cmp` exit 0).
* **Device identity does NOT survive:** `info --to` before `id=16e20688-...`, after `id=4fa77249-...`. The CLI creates a fresh UUID per process (`_selfFrom`) and keeps no state: two consecutive local `ls info` also differ (`bc61a71f`, `bb61e92e`). The `/config` volume exists but nothing writes to it. Consequence handled in the scripts: the printed link omits `id=` so it stays valid. Reported as a CLI gap.

## (d) `docker stop` during a transfer

400 MiB random file sent with `ls send --to 127.0.0.1:53418` in the background; stop issued once `rand400.bin.lspart` existed and about 1 s of data had flowed.

* In flight: `rand400.bin.lspart` 75,497,472 B + `rand400.bin.lspart.json` (resume map).
* `docker stop` -> exit 0 in 0.10 s; container `ExitCode=0`.
* Sender: exit 1, `FAILED NO_CONNECTION` (expected).
* After the stop: **no `rand400.bin`**; only the `.lspart` (75,497,472 B) and its `.json`. No corrupt final file.
* After `docker start`, re-sending the same file: exit 0, `COMPLETED`, only 352,321,536 of 419,430,400 bytes were sent (resumed), and `cmp` -> exit 0 (byte-identical).

## (e) Hardening and healthcheck

| Check | Result |
|---|---|
| `docker exec N id` | `uid=1000 gid=1000` (compose, host user), exit 0. Image default: `uid=10001(libreshare)` |
| Read-only rootfs | `ReadonlyRootfs=true`; `touch /usr/x`, `touch /etc/x` -> "Read-only file system" (1); `/tmp` (tmpfs), `/data`, `/config` writable |
| Capabilities / privileges | `CapDrop=[ALL]`, `/proc/self/status`: `CapEff 0000000000000000`, `NoNewPrivs 1`; limits `Mem=512 MiB`, `Pids=256`, 1.5 CPU; restart `unless-stopped` |
| Healthcheck command on a dead port | `docker run --rm IMAGE info --to 127.0.0.1:53318` -> exit 1 (Connection refused) |
| Healthcheck turns unhealthy | listener frozen with `kill -STOP` (found via `/proc`): `unhealthy` after **42 s** (10 s interval, 3 retries, 5 s timeout), container still running; `kill -CONT` -> `healthy` again within 9 s |
| Listener killed (`kill -KILL`) | container restarted by Docker (`restarts=1`), healthy again after 1 s |
| Entrypoint validation | `LS_PORT=abc` -> exit 64 + message; `LS_VISIBILITY=nobody` -> exit 64 + message; read-only `/data` -> exit 73 + hints (permissions, SELinux, read-only mount) |
| `LS_AUTO_ACCEPT=0` | prints the shorter warning that says every transfer is rejected without a terminal |
| Anonymous volumes | note: a plain `docker run` without `-v` creates two anonymous volumes because the image declares `VOLUME`; compose and the scripts mount explicit ones, so none are left (my own throwaway ones were removed by name) |

## (f) Windows-style compose, on Linux (Docker semantics only)

This runs `compose.windows.yaml` (bridge network + published ports) on Linux. It validates the compose file and the link method; it does **not** reproduce Docker Desktop's VM/NAT, Windows paths, Defender or PowerShell.

* `up -d` exit 0; `docker port`: `53418/tcp` and `53418/udp` published on 0.0.0.0 and [::]; `NetworkMode=libreshare-install-test_default`, container IP `172.19.0.2`.
* `ls send --to 127.0.0.1:53418 rand20.bin` -> exit 0, `cmp` exit 0 (data in a chcon'd bind folder, `LS_UID/LS_GID` set).
* Link method: the container prints `libreshare://peer?ip=172.19.0.2&port=53418&id=34b8911f-...&n=dk-test-win`; the scripts' rewrite (`s/([?&])ip=[^&]*/\1ip=<host IP>/`, drop `&id=`) gives `libreshare://peer?ip=192.168.29.189&port=53418&n=dk-test-win`, **which points at the host IP** (asserted in the script). `ls peer-link '<that link>'` -> exit 0 (`DEVICE ... 192.168.29.189:53418 via=qr`) and `ls send --device '<that link>' rand1.bin` -> exit 0, `cmp` exit 0.
* Observed once during development (not in the final log): `ls devices` on this Linux host also listed the bridged container (at 172.19.0.2) via multicast, and the container-IP link resolved too. That works only because a Linux host sits directly on the Docker bridge; on Windows/macOS the host is not on the container's network, so this proves nothing about Docker Desktop.
* First attempt without `user:` in the file on this SELinux host: the container exited 73 in a restart loop with the entrypoint's actionable message (the guard works); `user:` and a chcon'd folder fixed it. `compose.windows.yaml` now has the same `LS_UID/LS_GID` knob (default 10001).

## (g) `deploy/install.sh` end to end

With `LS_ENV_FILE=<scratch>/g.env LS_PROJECT=libreshare-install-test`, data folder `<scratch>/data g (space)` (a path with spaces and parentheses on purpose):

| Step | Result |
|---|---|
| before | no libreshare container/network/volume; image present |
| `deploy/install.sh --data-dir ... --port 53418 --alias dk-install` | **exit 0**; healthy; printed alias, `192.168.29.189:53418`, folder, link `libreshare://peer?ip=192.168.29.189&port=53418&n=dk-install`, firewalld commands, the plaintext warning |
| `deploy/install.sh --status` | exit 0 (`state=running health=healthy`, 0 files) |
| re-run `deploy/install.sh` | exit 0, compose said `Running` (idempotent, nothing recreated) |
| `ls send --device '<link>' rand5.bin`; `ls send --device dk-install rand5.bin` | both exit 0; `cmp` exit 0; second copy saved as `rand5 (1).bin` |
| `echo n \| deploy/install.sh --uninstall` | **exit 0**: container removed, image `libreshare/node:local` removed, data folder **kept** (2 files, 10 MiB, plus the `.libreshare-data` marker), settings file kept |
| after | `docker ps -a` (name `libreshare*` and label `dev.libreshare.install=1`): none; `docker network ls`: none (host networking creates none); `docker images libreshare/*`: none (only the pre-existing `libreshare-e2e/ls:local` of the E2E test); **the state volume `libreshare-install-test_config` is kept on purpose** (empty today; it will hold the identity), removed by me afterwards |
| `deploy/install.sh --status` after | exit 3 ("not installed or removed") |

Extra runs of the final script (all exit 0, nothing left behind except what is stated):

* `echo delete | deploy/install.sh --uninstall` on a folder the installer created: `Deleted ...`, state volume removed.
* The same answer on a folder the installer did **not** create (a pre-existing folder holding `mine.txt`): refused with a WARNING, both files still there, uninstall exit 0.
* `deploy/install.sh --nat --data-dir <chcon'd folder>` on Linux (uses `compose.windows.yaml`, i.e. the macOS/Docker-Desktop path, host-IP detection included): exit 0, printed the NAT note and a link with the host IP, `ls send --device '<link>'` exit 0, `cmp` exit 0, `--uninstall --keep-data` exit 0 (files kept).
* A final install, `docker exec ... send`, `echo delete | ... --uninstall`: exit 0.

Sending *from* the container: `docker exec N libreshare send --to 192.168.29.189:53418 /data/hello.txt` -> exit 0, `COMPLETED`; `docker exec N libreshare devices --timeout 3` -> exit 0, lists the node (host networking). `ss -ltn`: the listener is `0.0.0.0:53418` (IPv4 only); UDP `0.0.0.0:53318` for discovery.

## (h) Existing E2E untouched

`tools/docker/run_local.sh` (full run, 1 GiB datapoint included) -> **exit 0, `RESULT: PASS (docker e2e, 93 s incl. build)`**, `31 passed, 0 failed`. No file under `tools/docker/` was modified; `libreshare-e2e` containers and network were torn down by the script.

## Not verified / limits of this report

* **`deploy/install.ps1` has never run or been parsed** (no PowerShell on this machine, and fetching one was not attempted: downloading and running external code was refused by the sandbox for another image, so I did not try for this either). Its logic mirrors `install.sh`; the Windows-specific parts (adapter selection with `Get-NetIPConfiguration`, `Get-NetTCPConnection`, BOM-less `.env`, the firewall check, `Read-Host`, 5.1 vs 7 differences) are untested.
* **Docker Desktop on Windows/macOS**: no host available. That multicast does not cross its NAT, that the published UDP/TCP port is reachable from the LAN, that bind mounts from `C:\Users\...` are writable by uid 10001, and that the WSL2 backend builds the image are all reasoned, not observed.
* **A second physical device** on the LAN was never involved: "LAN visibility" was shown only host-to-container on one machine (multicast loopback on the host network).
* `shellcheck` could not be run (see above).
* arm64 images, Podman, rootless Docker: untested.

## Gaps for the CLI (not changed; `packages/` is off limits here)

1. `receive --advertise-ip ADDR`: `peer-link --ip` only *binds*; it cannot announce the Windows host's address from inside the container (it fails: not a local address). The scripts rewrite `ip=` in the printed link instead.
2. A state directory (`--state-dir /config`) so the device id survives restarts.
3. `info`/`devices` print an unhandled `FileSystemException: Broken pipe` when stdout closes early (`ls info | head -1`).
