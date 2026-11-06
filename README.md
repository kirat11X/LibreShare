# LibreShare

LibreShare is a free, open-source peer-to-peer file-sharing app for Windows, Linux and Android (macOS best effort). Two devices on the same network find each other, the receiver approves the transfer, and the files move directly between them in 4 MiB chunks that are each checked with SHA-256, so interrupted transfers resume instead of restarting. When no local path works, an end-to-end-encrypted internet tunnel is the last resort.

It is built as a Flutter UI on top of a GUI-free, pure-Dart core package that speaks a LocalSend-style protocol, **LSP/1** ([docs/protocol/LSP-1.md](docs/protocol/LSP-1.md)). Because the core has no Flutter imports, everything that matters (discovery, transfer, security, fallback) is tested headlessly through a CLI and Docker networks, with no screen or Wi-Fi radio required.

## Status

The current target is an **MVP** ([docs/plans/mvp.md](docs/plans/mvp.md)): send files between personal devices (Android <-> Linux, and Windows) on the same Wi-Fi, encrypted and verified, with a usable Flutter app. Subsequent features (Increments 4–7: connection ladder, internet tunnel, BLE/hotspot, background receive service) are deferred post-MVP.

| Increment / Stage | Scope | Status | Evidence / Reference |
|---|---|---|---|
| Increments 1–2 | Protocol, transfer, discovery (multicast, mDNS, subnet scan, QR/manual), Linux/Windows/Android app shell, tray, receive mode | **Done** | Emulator-verified Android <-> Linux transfers up to 600 MiB; see [docs/dev/testing-prototype.md](docs/dev/testing-prototype.md) |
| Increment 3 | Security & verification: TLS 1.3 with certificate pinning, signed client proof, SAS 6-digit code, PIN, consent, signed goodbye, Contacts-only gate | **In progress** | Building blocks reviewed with ~180 mutation checks; engine + CLI wiring in progress |
| MVP-App & F3 | Security screens in app (SAS display, PIN, key-change warning), Android download folder and usability fixes | In progress / Planned | [docs/plans/mvp.md](docs/plans/mvp.md) |
| Increments 4–7 | Connection ladder & resume, internet tunnel, free rendezvous, BLE/hotspot, packaging | Deferred (post-MVP) | [docs/plans/mvp.md](docs/plans/mvp.md) |

For live development status, see [docs/plans/STATUS.md](docs/plans/STATUS.md). Per-requirement traceability is tracked in [docs/traceability.md](docs/traceability.md). Prototype testing instructions are in [docs/dev/testing-prototype.md](docs/dev/testing-prototype.md).

## What "WiFi" and "LAN" mean here

The connection ladder is **WiFi path -> LAN path -> Internet tunnel**, but "WiFi" and "LAN" are **path tiers, not radio technologies**. LibreShare does not drive Wi-Fi hardware and it does not implement Wi-Fi Direct or AWDL (programmatic Wi-Fi Direct is impossible on Apple platforms and fragile elsewhere).

- **WiFi tier** - a direct connection to the peer's address on the shared (Wi-Fi) network; later, optionally, a hotspot the app helps create.
- **LAN tier** - every other local path: Ethernet, a second network interface, another private subnet, IPv6 link-local, a manually entered or QR-scanned address.
- **Tunnel tier** - the sender hosts an end-to-end-encrypted (AES-256-GCM) origin behind a Cloudflare Quick Tunnel (zrok as backup); the receiver pulls from it. The tunnel provider only sees ciphertext.

Candidates are tried in order, like ICE, and the transfer resumes from its chunk bitmap on the next one. See the build spec sections 2, 6 and 7 ([docs/LIBRESHARE_BUILD_SPEC.md](docs/LIBRESHARE_BUILD_SPEC.md)) and [ADR 0002](docs/adr/0002-connection-ladder-as-candidates.md).

## Repository layout

```
.
├── CLAUDE.md                       guide and rules for Claude Code sessions
├── README.md
├── pubspec.yaml                    Dart pub workspace root
├── analysis_options.yaml           lints (strict-casts, strict-raw-types)
├── .fvmrc                          pinned Flutter 3.47.9 (Dart 3.13.7)
├── docs/
│   ├── LIBRESHARE_BUILD_SPEC.md    source of truth for scope, protocol and increments
│   ├── protocol/LSP-1.md           normative wire protocol (+ schemas/*.schema.json)
│   ├── traceability.md             FR-01..FR-17 / NFR-01..NFR-08 -> module -> test
│   ├── plans/                      one plan per increment (inc1.md, ...)
│   ├── adr/                        architecture decision records
│   ├── dev/                        guides for install, testing, and prototypes
│   └── test-reports/               manual and live test records
├── packages/
│   ├── libreshare_core/            pure-Dart core: model, transfer, server, client, discovery, security (later: connection, tunnel)
│   └── libreshare_cli/bin/ls.dart  CLI: info | receive | send (later: devices, link)
├── apps/libreshare_app/            Flutter UI (Increment 2 onwards)
├── tools/                          env.sh, docker/, netem/, bench/
├── deploy/                         install scripts and headless Docker node
└── .github/workflows/ci.yml        CI
```

Directories marked "later" appear when the increment that needs them starts.

## Quick start

The project uses a project-local, gitignored toolchain (`.toolchain/`: Flutter 3.47.9 / Dart 3.13.7). If you already have those versions on `PATH` (for example through `fvm`, version in `.fvmrc`), you can skip the first line.

```bash
source tools/env.sh            # puts Flutter/Dart on PATH, sets PUB_CACHE=.toolchain/pub-cache
dart pub get                   # resolves the whole workspace from the repo root

# tests and static checks
(cd packages/libreshare_core && dart test)
dart analyze --fatal-infos
dart format --output=none --set-exit-if-changed .

# loopback transfer (CLI receive and send)
dart run packages/libreshare_cli/bin/ls.dart receive --port 53400 --dir /tmp/rx --auto-accept &
dart run packages/libreshare_cli/bin/ls.dart send --to 127.0.0.1:53400 file.bin
cmp file.bin /tmp/rx/file.bin
```

Older prototype builds use unencrypted HTTP; secure transfers use TLS 1.3 by default (use `--insecure-plaintext` on loopback or test networks only if unencrypted HTTP is needed).

Run a single test: `cd packages/libreshare_core && dart test test/unit/chunker_test.dart -N "last chunk"`.

## Install

Pre-built prototype artifacts reside in `dist/prototype/` (validated with `sha256sum -c SHA256SUMS`). Detailed testing steps and platform notes are in [docs/dev/testing-prototype.md](docs/dev/testing-prototype.md).

- **Linux:**
  Extract and run the Linux x64 bundle:
  ```bash
  tar xzf libreshare-1.0.0-linux-x64.tar.gz && cd libreshare-1.0.0-linux-x64 && ./libreshare_app
  ```
  Requires GTK 3. Allow UDP 53318 and TCP 53318–53327 on your private network (e.g. Fedora: `sudo firewall-cmd --add-port=53318/udp --add-port=53318-53327/tcp`, add `--permanent` to persist). Received files go to `~/Downloads/LibreShare`.

- **Android:**
  Install the APK on an Android 10+ device (`adb install -r libreshare-1.0.0-android-arm64-v8a.apk` or copy the APK to the phone and allow "install unknown apps"). Use `libreshare-1.0.0-android-arm64-v8a.apk` for modern phones or `libreshare-1.0.0-android-universal.apk` if needed. Install only one flavour (version-code constraint requires an uninstall before switching flavours). Keep the app open and screen on during transfers.

- **Docker (Headless Node):**
  A headless LibreShare node ("drop box" service that receives into a folder and can also send) installs with one command:
  - Linux (Docker Engine): `deploy/install.sh`
  - Windows/macOS (Docker Desktop with WSL2 backend and Linux containers): `powershell -ExecutionPolicy Bypass -File deploy\install.ps1`
  Full options, limits, and troubleshooting: [docs/dev/docker-install.md](docs/dev/docker-install.md).

- **Windows:**
  Build via Windows PC or GitHub Actions; not built yet. Flutter cannot cross-compile Windows binaries on Linux. To build: run `tools/package_prototype.sh windows` on a Windows machine with Flutter 3.47.9 and Visual Studio C++ build tools, or trigger the GitHub Actions workflow (`.github/workflows/prototype.yml`). Details in [docs/dev/testing-prototype.md](docs/dev/testing-prototype.md) and [docs/dev/prototype-1.md](docs/dev/prototype-1.md).

## Known limits

Copied and tracked from [docs/dev/prototype-1.md](docs/dev/prototype-1.md) and [docs/dev/testing-prototype.md](docs/dev/testing-prototype.md):

- **Encryption and authentication**: Transfers are encrypted from the secure build on (TLS 1.3 with pinned certificates, SAS 6-digit verification code, optional PIN, and consent prompt); the older prototype APKs are not.
- **Same Wi-Fi/LAN only**: No internet fallback, no link sharing, no BLE/hotspot yet (Increments 4–7 are deferred post-MVP).
- **Speed**: Speed on loopback is ≈ 30 MB/s (CPU-bound hashing, NFR-02 not met; Increment 4 profiles and fixes it). Real Wi-Fi is usually slower than that anyway.
- **Receive mode**: Receive is Off at first launch (nothing is visible to others until you turn it on).
- **QR scanning**: QR scanning uses `mobile_scanner` (Google ML Kit); behaviour on phones without Google services (e.g. Huawei) is unverified.
- **Background operation**: Transfers require the app to stay in the foreground with the screen on (Android blocks network access a few seconds after leaving the foreground; keep-screen-on is enabled while visible; background service is deferred post-MVP).

## How the project is developed

- One increment at a time (spec section 12); each starts with `docs/plans/inc<N>.md`, then failing tests, then code. Acceptance tests are never edited to make them pass.
- A protocol change updates `docs/protocol/LSP-1.md`, the JSON schemas and the conformance tests in the same pull request.
- `packages/libreshare_core` must never import Flutter (CI greps for it). All I/O sits behind interfaces so it can be faked in tests.
- Never log file contents, keys, PINs or tunnel URL fragments.

## Platform and tunnel notes

- Targets: Linux x64, Windows 10/11 x64, Android 10+ (MVP); macOS 12+ best effort; iOS is a stretch goal (needs a paid account and the multicast entitlement; mDNS only).
- Cloudflare Quick Tunnels are documented as "for testing and development" with no uptime guarantee; LibreShare uses them only for user-initiated, short-lived transfers and always encrypts payloads end to end. Teams that need reliability can self-host zrok or frp.

## License

MIT — see [LICENSE](LICENSE).
