# Testing the prototype: Android -> Linux and Android -> Windows

Files are in `dist/prototype/` (check them with `cd dist/prototype && sha256sum -c SHA256SUMS`).
Status of what is proven is in the last section. Short version: **Android -> Linux was run end to end on an Android 15 emulator** (byte-identical files up to 600 MiB); a real phone on real Wi-Fi, and everything on Windows, has not been run by anyone yet.

> **Prototype = no encryption, no authentication.** Use it only on a network you trust (your home Wi-Fi), never on public or shared Wi-Fi. Encryption comes with Increment 3.

## 0. What you need

| Test | Files |
|---|---|
| Android phone -> Linux PC | `libreshare-1.0.0-android-arm64-v8a.apk` (nearly every phone since 2016; if the install says "not compatible", use `...-universal.apk`) and `libreshare-1.0.0-linux-x64.tar.gz` |
| Android phone -> Windows PC | the same APK, plus a Windows receiver: **either** the Docker node (section 3a, works today) **or** the Windows app (section 3b, needs a GitHub Actions build that has not been run) |

Phone and PC must be on the **same Wi-Fi / LAN**. Many routers have "AP / client isolation" or a separate "guest network" that blocks device-to-device traffic: if nothing is found or sending fails, check that first.

## 1. Install

**Android:** copy the APK to the phone (or `adb install -r libreshare-1.0.0-android-arm64-v8a.apk`), open it, allow "install unknown apps" for the app you opened it from. Install only ONE flavour: switching between the universal and a per-ABI APK needs an uninstall first (version-code mismatch).

**Linux:**
```bash
tar xzf libreshare-1.0.0-linux-x64.tar.gz && cd libreshare-1.0.0-linux-x64 && ./libreshare_app
```
Needs GTK 3. Open the firewall for the private network (Fedora example; `--permanent` keeps it):
```bash
sudo firewall-cmd --add-port=53318/udp --add-port=53318-53327/tcp
```
Received files go to `~/Downloads/LibreShare` (shown in Settings -> Download folder).

## 2. Android -> Linux

1. **Linux:** start the app, turn the **Receive** switch on (Home or Settings). Find the PC's address with `ip -4 addr` (for example `192.168.1.20`).
2. **Android:** open LibreShare. **Keep the app open and the screen on for the whole transfer** (see "Known problems": the prototype stops when the app is in the background).
3. Does the Linux PC appear under **Nearby**? If yes, skip to step 5. If not (multicast is often blocked on Wi-Fi): top-right icon **Add device** -> field **IP address (and port)** -> type `192.168.1.20` (add `:53318` if you changed the port) -> **Look up** -> **Add**.
4. Tap **Send files**, pick one or more files (long-press to select several, then **Select**).
5. On the screen **Send files** -> **Choose a device**: **tap the device card** (there is no separate Send button; the tap starts the transfer).
6. **Linux** shows the dialog **Incoming transfer** -> **Accept**. The phone shows progress, then "Sent N files to ..." -> **Done**.
7. Check: the file is in `~/Downloads/LibreShare`; `sha256sum` it against the original if you want proof.

Reverse direction (Linux -> Android): turn **Receive** on in the phone app (chips 15 min / 1 h / 6 h), keep it open, on Linux **Add device**/pick the phone, **Send files**, then tap **Accept** on the phone.

Headless alternative for the Linux side (no GUI): `dart run packages/libreshare_cli/bin/ls.dart receive --port 53318 --dir ~/rx --auto-accept` from the repository (the CLI now defaults to the encrypted profile; app builds made before card D1 are still plaintext, so add `--insecure-plaintext` to both `receive` and `send` when talking to such an app build; after D1 drop the flag).

## 3. Android -> Windows

### 3a. Today: the Docker node on Windows (a drop box, no window)

Needs Docker Desktop (WSL2 backend, Linux containers). In PowerShell in the repository folder:
```powershell
powershell -ExecutionPolicy Bypass -File deploy\install.ps1
```
It prints a `libreshare://peer?...` link and your PC's LAN IP. Windows may ask to allow Docker Desktop on **Private networks**: allow. Details and caveats: `docs/dev/docker-install.md`.

On Android there is no auto-discovery for this node (Docker Desktop hides the LAN from the container): **Add device** -> **IP address (and port)** -> `<windows-pc-ip>` -> **Look up** -> **Add** (or **Device link** -> paste the printed link -> **Add from link**) -> **Send files** -> tap the device card. The node auto-accepts and saves into `%USERPROFILE%\LibreShare`.

`install.ps1` has **never been executed** (it was written and reviewed on Linux). If it fails, tell me the first red line of its output.

### 3b. The real Windows app (not built yet)

Flutter cannot build Windows on Linux. Two ways, both need you: (1) on a Windows PC with Flutter 3.47.9 and Visual Studio Build Tools "Desktop development with C++": `tools/package_prototype.sh windows` in Git Bash; (2) a free GitHub Actions run (`.github/workflows/prototype.yml`, "Run workflow") which needs the repository on GitHub. **I have not pushed anything** (you said not to); say so if you want me to create a private repository and run it. Expect the first Windows build to need a fix or two: the Windows C++ runner, registry autostart and tray code have never been compiled.

## 4. Known problems (found on the emulator, fixes are queued)

| Problem | What you will see | Workaround now |
|---|---|---|
| App in background or screen off kills the transfer (Android blocks its network ~5 s later) | send shows "Could not reach ..."; the PC keeps a dead session | keep the app visible. The build keeps the screen on while the app is open. Real fix: Increment 3 foreground service |
| Received files on Android land in `Android/data/dev.libreshare.libreshare_app/files/Download/LibreShare`, which the Files app cannot show; **Open** / **Show in folder** do nothing | "Could not open it here. The file is saved at ..." | Settings -> **Download folder** -> create a new folder under Download -> **Use this folder** -> **Allow** |
| Devices added by IP/link vanish from Nearby after ~90 s | "No devices found yet" when sending | add the device again |
| The phone calls itself `localhost` | name on the PC's prompt | rename in Settings -> **Device name** |
| A receiver never times out a stalled session | "Receiving 48 %" forever on the phone; `.lspart` left on the PC | restart the receiver |
| Speed | emulator numbers: ~11 MiB/s Android -> Linux (NAT), real Wi-Fi unmeasured | - |

## 5. What is proven and what is not

Proven (emulator, `docs/test-reports/android-emulator.md`, `tools/android_emulator_smoke.sh` PASS 18/18 three times): install and launch of the exact APK, Android -> Linux and Linux -> Android with 1 KiB, 20 MiB, 120 MiB (and 600 MiB Android -> Linux) byte-identical, cancel mid-transfer, receiver rejects, receiver offline message, add-by-IP and add-by-link, no clobbering of equal names.
Not proven: a real phone and real Wi-Fi (battery managers, multicast/mDNS discovery between devices, speed), the camera/QR scan, notifications, arm64/armv7 builds beyond "they built", any Windows binary, `install.ps1`, Linux release bundle's window and Receive toggle (it was started headless for 14 s).
