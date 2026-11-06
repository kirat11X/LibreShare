# Prototype 1 (Increment 2 build) — what exists, how to install, what is NOT proven

Built 2026-11-04 on the dev box by `tools/package_prototype.sh` (exit 0). Artefacts are in `dist/prototype/` (gitignored) with `SHA256SUMS`.

| Platform | File | Size | Built here? | Run here? |
|---|---|---|---|---|
| Linux x64 | `libreshare-1.0.0-linux-x64.tar.gz` | 11.6 MB | yes (`flutter build linux --release`) | started `--hidden` for 14 s from the tarball with isolated XDG dirs: no missing libraries, UDP 53318 joined, no autostart entry created, no crash. No window seen; Receive toggle not exercised on the release binary |
| Android (any phone) | `libreshare-1.0.0-android-arm64-v8a.apk` (29 MB, modern phones), `…-armeabi-v7a.apk` (25 MB, old 32-bit), `…-x86_64.apk` (32 MB, emulators/ChromeOS), `…-universal.apk` (81 MB, all three) | | yes (`flutter build apk --release`, AGP 9.1 / Kotlin 2.4 / Gradle 9.3.1) | **emulator only** (Android 15 x86_64, 2026-11-05): installs, launches, sends to and receives from the Linux CLI, byte-identical up to 600 MiB (`docs/test-reports/android-emulator.md`, `tools/android_emulator_smoke.sh`). Never on a real phone. The APKs were rebuilt after that run (keep-screen-on fix), see `SHA256SUMS`. Step-by-step: `docs/dev/testing-prototype.md` |
| Windows x64 | none | | **no** — Flutter needs MSVC on Windows | **no** |

The Android APKs are **signed with the debug key** (prototype sideloading only; no Play Store, no update continuity once a real key is used). Package `dev.libreshare.libreshare_app`, minSdk 24, targetSdk 36.

## Install

- **Linux:** `tar xzf libreshare-1.0.0-linux-x64.tar.gz && cd libreshare-1.0.0-linux-x64 && ./libreshare_app`. Needs GTK 3. Allow UDP 53318 and TCP 53318–53327 on your private network (Fedora: `sudo firewall-cmd --add-port=53318/udp --add-port=53318-53327/tcp`, add `--permanent` to keep). GNOME shows no tray without the AppIndicator extension; the app then minimizes instead.
- **Android:** enable "install unknown apps", then `adb install libreshare-1.0.0-android-arm64-v8a.apk` or open the file on the phone. Foreground only: discovery, sending and receiving work only while the app is open and the screen is on (Android blocks its network a few seconds after it leaves the foreground; the build sets keep-screen-on while the app is visible; the background `ReceiveService` is Increment 3).
- **Windows:** build it (below). On first run Windows Defender Firewall will ask to allow the app on private networks: say yes.

## Get the Windows build (needs something only you can do)

Option A — GitHub Actions (free runner): put the repo on GitHub (it is not a git repository yet), push, then Actions → "prototype" → Run workflow. It builds Linux, Android and **Windows** and uploads one artifact per platform. Pushing a tag `v0.1.0-proto1` also creates a pre-release with the files.

Option B — on a Windows PC: install Flutter 3.47.9 and "Desktop development with C++" (Visual Studio Build Tools), then in Git Bash: `tools/package_prototype.sh windows` → `dist/prototype/libreshare-1.0.0-windows-x64.zip`.

The Windows C++ runner edits, the HKCU `Run` autostart and the tray/window code were **never compiled or run** (only unit-tested through fakes). Expect the first Windows build to need a fix or two.

## What the prototype does (Increment 2)

Discovery (multicast, mDNS, subnet scan, QR/manual link) → pick a device → send files → the receiver gets an Accept/Reject prompt → resumable 4 MiB chunked transfer with checksums. Receive mode Off / For N minutes / Always, tray, start-with-OS (opt-in), My QR / scan QR.

## What it does NOT do yet — do not use on an untrusted network

- **No encryption or authentication** (plain HTTP). Anyone on the same network can see or intercept transfers. Increment 3 adds TLS pinning, SAS and PIN.
- Same Wi-Fi/LAN only (no internet fallback, no link sharing, no BLE/hotspot) — Increments 4–7.
- Speed on loopback is ≈ 30 MB/s (CPU-bound hashing, NFR-02 not met); Increment 4 profiles and fixes it. Real Wi-Fi is usually slower than that anyway.
- Receive is Off at first launch (nothing is visible to others until you turn it on).
- QR scanning uses `mobile_scanner` (Google ML Kit); behaviour on phones without Google services (e.g. Huawei) is unverified.
