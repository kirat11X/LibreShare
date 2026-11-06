# Docker install: a headless LibreShare node (prototype)

One command builds and starts a small container that runs LibreShare's `receive` as a service: a **drop box** that stays up, saves what other devices send into a folder you choose, and can also send files. Files for this live in `deploy/`; how it was tested is in `docs/test-reports/docker-install.md`.

## What this is, and is not

| It is | It is not |
|---|---|
| The AOT-compiled CLI (`libreshare`, same code as `ls receive`) in a ~95 MB Debian-slim image (33 MB compressed), non-root, read-only root filesystem, no capabilities | The Flutter app. The GUI is **not** containerised (a desktop UI in a container makes no sense); use the Linux/Android/Windows app for that |
| A node other devices can find (Linux: automatic) or reach by link / `IP:port` | Encrypted or authenticated. **Prototype: plain HTTP, no TLS, no PIN, auto-accept on.** Increment 3 adds TLS/PIN |
| Built on your machine from this repository (`libreshare/node:local`) | A published image. Nothing is pulled from a registry except the `dart` and `debian` base images at build time |
| Linux (Docker Engine), Windows 10/11 and macOS (Docker Desktop) | Windows *native* containers. This is a Linux binary; Docker Desktop must be in **Linux containers** mode (WSL2 backend) |

> **Security: read this once.** Transfers are NOT encrypted or authenticated and anyone on this network can drop files into the received folder. Use only on a trusted private network (Increment 3 adds TLS/PIN). Do not run it on public Wi-Fi, a campus network, or anything forwarded to the internet. The container prints this warning on every start.

## Linux quickstart (Docker Engine)

Prerequisites: Docker Engine and the Compose v2 plugin (`docker compose version` works), and your user may talk to Docker (`docker info` works without `sudo`).

```bash
git clone <this repo> && cd <repo>
deploy/install.sh                       # builds, starts, waits until healthy, prints the link
deploy/install.sh --status              # state, health, link, how many files arrived
```

The default received-files folder is `~/LibreShare`. Options: `--data-dir DIR`, `--port N`, `--alias NAME`, `--project NAME`. Settings are remembered in `deploy/docker/.env`; re-running the script is safe (it rebuilds and re-creates the container, keeps your files and settings).

How it works on Linux: `compose.linux.yaml` uses **host networking**. LAN discovery is UDP multicast (`224.0.0.168:53318`) plus mDNS and Docker bridge networks do not forward LAN multicast, so with host networking the node appears in other devices' lists and sees theirs. The price is that Docker does not open any firewall port for you. If `firewalld` or `ufw` is active, allow the node (the script prints the exact commands and never runs them):

```bash
sudo firewall-cmd --add-port=53318/tcp --add-port=53318/udp            # now
sudo firewall-cmd --permanent --add-port=53318/tcp --add-port=53318/udp
```

Check from another device on the same Wi-Fi/LAN: it should list the node's alias (the Linux/Android app, or `ls devices` from the CLI).

## Windows quickstart (Docker Desktop, WSL2, Linux containers)

Prerequisites, once:

1. Windows 10 22H2 / Windows 11 with virtualization enabled in the BIOS.
2. [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/) with the **WSL 2 backend**. Start it and wait for "Engine running". If a tray menu says "Switch to Windows containers...", you are already in Linux mode (good); if it says "Switch to Linux containers...", click it.
3. Git (or download the repository as a ZIP).

Then, in PowerShell (5.1 or 7) in the repository folder:

```powershell
powershell -ExecutionPolicy Bypass -File deploy\install.ps1
deploy\install.ps1 -Status        # later (or the same command with -ExecutionPolicy Bypass)
```

`-ExecutionPolicy Bypass` affects only that one process; it is needed when your PC blocks local scripts. Options: `-DataDir`, `-Port`, `-Alias`, `-HostIp`, `-Project`.

What to expect, honestly:

* **No auto-discovery.** Docker Desktop runs containers in a VM behind NAT; LAN multicast does not cross it, so other devices will **not** see the node in their list. They connect with the **peer link** the script prints (`libreshare://peer?ip=192.168.x.y&port=53318&n=...`: paste it into the app's "Add device by link", scan it as a QR, or `libreshare send --device '<link>' FILE`) or by typing `IP:port`.
* **The link carries your PC's LAN IP**, not the container's. The node itself only knows its internal `172.x` address, so `install.ps1` detects your primary private IPv4 (the adapter with the default route; virtual WSL/Hyper-V/VPN adapters are skipped) and rewrites the link. If it picks the wrong adapter: `-HostIp 192.168.1.20` (`ipconfig` shows yours). If your DHCP address changes, run `-Status` again to get the new link.
* **Windows Defender Firewall.** Docker Desktop's first publish of the port may pop up "Allow Docker Desktop Backend": allow **Private networks**. Or create the rules yourself in an **administrator** PowerShell (the script prints them and never runs them):

  ```powershell
  New-NetFirewallRule -DisplayName "LibreShare node 53318 TCP" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 53318 -Profile Private
  New-NetFirewallRule -DisplayName "LibreShare node 53318 UDP" -Direction Inbound -Action Allow -Protocol UDP -LocalPort 53318 -Profile Private
  ```
* Received files appear in `%USERPROFILE%\LibreShare` (a normal Windows folder).

## macOS

Docker Desktop for Mac behaves like the Windows case (VM + NAT): `deploy/install.sh` detects macOS, uses `compose.windows.yaml` (published ports), prints a link carrying the Mac's LAN IP and says plainly that auto-discovery will not work. Allow incoming connections for Docker if macOS asks. **Never tested on a Mac** (no Mac available while this was written). `--nat` forces this mode on any OS.

## Settings

Container environment variables (the entrypoint maps them to `libreshare receive` flags). With the compose files they come from `deploy/docker/.env` (written by the install scripts; edit and re-run the script or `docker compose up -d`).

| Variable | Default | Meaning |
|---|---|---|
| `LS_ALIAS` | host/container name | Name other devices show. The scripts default to `libreshare-<hostname>` |
| `LS_PORT` | `53318` | TCP port of the API (host and container port are the same, because the node advertises it). Discovery stays on UDP 53318 |
| `LS_AUTO_ACCEPT` | `1` | `1/true/yes/on`: accept every incoming transfer. **On by default only because a headless box has nobody to click Accept.** With `0` the CLI asks on stdin, which only works with `docker attach` / `docker run -it`; otherwise every transfer is rejected |
| `LS_VISIBILITY` | `everyone` | `everyone` or `contacts` (`contacts` needs pairing, which does not exist yet: the CLI refuses it) |
| `LS_EXTRA_ARGS` | empty | Extra `receive` flags split on spaces, e.g. `--no-discovery` or `--for 2h` |
| `LS_DATA_DIR` (compose only) | `~/LibreShare` / `%USERPROFILE%\LibreShare` | Host folder mounted at `/data` |
| `LS_UID`, `LS_GID` (compose only) | your ids on Linux; `10001` on Windows/macOS | The container runs as this user so received files in the bind-mounted folder are yours |
| `LS_PROJECT` (install.sh only) | `libreshare` | Compose project name, to run a second node (use another `--port` and `--data-dir` too) |

Volumes: `/data` = received files (bind mount, yours); `/config` = state (named volume `<project>_config`, **unused by the prototype CLI**; reserved for the device identity and keys of Increment 3).

## Sending files

**To the container** from any device: use the link, `IP:port`, or on Linux the alias. From a machine with the CLI: `libreshare send --device libreshare-myhost FILE` (Linux) or `libreshare send --device 'libreshare://peer?ip=...&port=53318&n=...' FILE`.

**From the container.** The root filesystem is read-only, so put the file where the container can read it, then use `docker exec` (the name is printed by the script; default `libreshare-libreshare-1`):

```bash
cp photo.jpg ~/LibreShare/                      # /data inside the container
docker exec libreshare-libreshare-1 libreshare send --to 192.168.1.50:53318 /data/photo.jpg
docker exec libreshare-libreshare-1 libreshare devices --timeout 5      # Linux/host networking only
```

`send` runs its own short-lived client; it does not disturb the listener.

## Upgrade

```bash
git pull
deploy/install.sh            # Windows: deploy\install.ps1   -> rebuilds, re-creates the container
docker image prune           # optional: drop the old image layers
```

Files in the received folder and the settings file are kept. The device id (and so the link's `id=`) changes on every start in the prototype (see Known limits); the printed link does not contain it, so it keeps working.

## Uninstall

```bash
deploy/install.sh --uninstall        # Windows: deploy\install.ps1 -Uninstall
```

Stops and removes the container and the image `libreshare/node:local`. **It never deletes received files silently:** it shows how many files are in the folder and only deletes if you type `delete` (and only for a folder the installer created itself; it refuses `/`, your home, the repository, or any folder it did not create). `--keep-data` / `-KeepData` skips the question and keeps everything. Kept: the settings file `deploy/docker/.env` and the state volume `<project>_config`, so a later install resumes where you left off (`docker volume rm <project>_config` removes it; answering `delete` removes it for you). The shared base images and the build cache are not touched (`docker image prune`, `docker builder prune`). Firewall rules you created yourself stay until you remove them: `Remove-NetFirewallRule -DisplayName "LibreShare node*"`.

## Known limits

* **Plaintext prototype** (see the warning above). Also no internet/tunnel fallback: same-network only, until Increments 4-5.
* **Windows/macOS: no auto-discovery** (Docker Desktop NAT); link or `IP:port` only. This was reasoned from how Docker Desktop works, not observed (see the test report).
* **New device id on every start.** The CLI generates a fresh UUID per process and keeps no state, so after `docker restart` the node has a new id. A link that pins the old `id=` is refused; the links printed by the scripts omit the id for that reason. The `/config` volume exists but is not used yet.
* Only receive mode "always" in the container; no history, no tray, no notifications; look at `docker logs` (`SESSION`, `RECEIVED <path>`, `COMPLETED`, `FAILED <reason>`).
* One node per host and port; a Linux host that also runs the LibreShare desktop app needs a different `--port` (the script checks for a busy TCP port).
* Images are built for your CPU architecture (amd64 tested; arm64 Macs should build natively, untested).
* An unhealthy container is reported but not restarted by Docker (a *crashed* node is restarted by `restart: unless-stopped`).
* The first build needs internet access (Docker Hub for the `dart` and `debian` images, pub.dev for packages) and takes a few minutes.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Script: "Docker is installed, but your user may not talk to it" | `sudo usermod -aG docker "$USER"`, log out and in (or `newgrp docker`) |
| Script: "daemon is not reachable" | Linux: `sudo systemctl enable --now docker`. Windows/macOS: start Docker Desktop and wait for "Engine running" |
| Windows: "running Windows containers" | Tray whale -> "Switch to Linux containers..." |
| Windows: script is blocked | `powershell -ExecutionPolicy Bypass -File deploy\install.ps1` |
| Container restarts forever / unhealthy | `docker logs <name>`. Exit **64** = bad `LS_*` value (message names it); exit **73** = `/data` is not writable (see SELinux and permissions below) |
| "TCP port 53318 is already in use" | The LibreShare desktop app or another node. `ss -ltnp 'sport = :53318'` (Windows: `Get-NetTCPConnection -LocalPort 53318`). Choose another: `--port 53319` / `-Port 53319` |
| Fedora/RHEL: "permission denied" writing to `/data` | SELinux. `compose.linux.yaml` already sets the bind option `selinux: z`. For your own `docker run`, use `-v ~/LibreShare:/data:z`. Use a folder dedicated to LibreShare: `z` relabels it, and Docker refuses system folders such as `/home` |
| Permission denied on a bind mount (other cases) | The container runs as `LS_UID:LS_GID`. Make the folder writable for that id, or `chown`. Rootless Docker / Podman remap ids: set `LS_UID=0` (maps to you in a rootless setup) - untested |
| Other devices cannot see the node (Linux) | Host firewall (see above); the network blocks multicast (some routers/APs filter it); **Wi-Fi "AP isolation" / "client isolation" / guest network** blocks device-to-device traffic entirely: neither discovery nor the link will work, use a normal network or a hotspot from one device |
| Other devices cannot connect by link (Windows/macOS) | Wrong IP in the link (`-HostIp`), firewall rule missing, or AP isolation. Test from the PC first: `libreshare send --to 127.0.0.1:53318 FILE` |
| IPv6 | The prototype advertises and uses IPv4 addresses only; IPv6-only networks are not supported |
| `docker compose` says the image is missing / not found | The image is built locally, never pulled (`pull_policy: never`); run the install script or add `--build` |
| Build fails on `pub get` / metadata | No access to pub.dev or Docker Hub (proxy, offline). Set Docker's proxy settings or retry online |
| Files from a Windows checkout break the container ("/bin/sh^M") | Handled: the Dockerfile strips CRs from the entrypoint, and `deploy/.gitattributes` keeps it LF |

## Gaps found (feature requests for the CLI, not done here)

1. **Advertised address.** `receive` has no way to announce an address other than the interfaces it sees. `peer-link --ip` is a *bind* address, not an advertised one: giving it the Windows host's IP inside the container fails (not a local address). The scripts work around this by rewriting `ip=` in the printed `PEER-LINK` line. A real `--advertise-ip ADDR` (used in `/info` `addrs`, the printed link and the discovery announce) would also fix what other devices learn from `/info` and from unicast discovery answers.
2. **Persistent device identity.** `_selfFrom` creates a new UUID per process; the node needs to load/save it (e.g. `--state-dir /config`) so ids, fingerprints and, in Increment 3, TOFU pins survive `docker restart`.
3. `info` / `devices` crash with an unhandled `FileSystemException: Broken pipe` when stdout is closed early (`ls info | head -1`). Cosmetic.
