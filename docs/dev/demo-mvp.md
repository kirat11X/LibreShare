# LibreShare MVP Demo Guide

A step-by-step guide to demonstrate the LibreShare Minimum Viable Product (MVP): sending files between devices (Android and Linux, and Windows) on the same Wi-Fi network, encrypted and verified.

## Status: what works today and what does not (2026-11-06)

**The Linux and Android builds in `dist/prototype/` made on 2026-11-06 at 09:22 or later use the secure engine** (TLS 1.3 with a pinned certificate, a 6-digit verification code on first contact, the PIN guard, refusal when a device's key changed). **Builds made before 09:22 on 2026-11-06 are PLAINTEXT: do not use or describe them as encrypted.** The command-line tool (`ls`) is encrypted by default. Check a download with `sha256sum -c SHA256SUMS`.

What was checked, and where (2026-11-06; `docs/test-reports/mvp-acceptance-secure.md`):

- **[VERIFIED on the Android emulator, `tools/android_emulator_smoke.sh`, 26 of 26 checks]** The sender screen shows "Verification code" with six digits ("Tell <name> to compare it, then wait for them to accept"); they are the same six digits the other side printed.
- **[VERIFIED on the Android emulator, receiving side]** The **Incoming transfer** dialog shows the sender, a **New device** badge, the heading **Verification code** with six digits, and "Ask <name> to read the code on their screen. Accept only if it is the same." **Accept** is disabled only until the code has been worked out; it is NOT disabled until the codes match, so the people must compare the digits themselves. The Linux desktop app uses the same dialog but was not started in the build container (no display); try it on your PC.
- **[VERIFIED on the emulator, by hand]** **Settings** -> **Fixed** -> a 6-digit PIN -> **Save** shows "PIN configured"; the identity and PIN files are mode 600 in a mode 700 folder (smoke check S7). A wrong PIN being refused is covered by automated tests with two real engines and by the CLI tests; it was not repeated on the device.
- **[COVERED BY AUTOMATED TESTS ONLY]** A peer whose security key changed is refused with a warning banner and no **Accept** button (core and CLI tests, CLI exit code 80, app widget tests). Not shown on a device.
- **[VERIFIED on the emulator]** **Settings** -> **Your fingerprint** shows 16 hex digits in groups of four (for example `1A1B 5D53 22F3 4BE6`) with a **Copy fingerprint** button.

---

## 1. Prerequisites

- **Network**: Both devices must be connected to the same Wi-Fi / LAN subnet. Many routers have "AP / client isolation" or separate guest networks that block device-to-device traffic.
- **Linux PC**:
  - 64-bit Linux (x86_64) with GTK 3.
  - Firewall ports opened for discovery and transfer: UDP 53318 and TCP 53318-53327.
- **Android Phone**:
  - Android 7.0+ (API 24 or newer).
  - App must stay open and visible in the foreground with the screen on for the entire transfer.
- **Packages**:
  - Linux: `libreshare-1.0.0-linux-x64.tar.gz` (in `dist/prototype/`).
  - Android: `libreshare-1.0.0-android-arm64-v8a.apk` (or `libreshare-1.0.0-android-universal.apk` if needed).

---

## 2. Installation

### Linux
1. Extract the tarball and run the application:
   ```bash
   tar xzf libreshare-1.0.0-linux-x64.tar.gz && cd libreshare-1.0.0-linux-x64 && ./libreshare_app
   ```
2. Open firewall ports (Fedora / firewalld example; add `--permanent` to persist):
   ```bash
   sudo firewall-cmd --add-port=53318/udp --add-port=53318-53327/tcp
   ```
3. Received files are saved to `~/Downloads/LibreShare` (shown in **Settings** -> **Download folder**).

### Android
1. Copy the APK (`libreshare-1.0.0-android-arm64-v8a.apk`) to the phone or install via ADB:
   ```bash
   adb install -r libreshare-1.0.0-android-arm64-v8a.apk
   ```
2. Allow "install unknown apps" if prompted.
3. *Note*: Install only one APK flavour. Switching between universal and per-ABI APKs requires an uninstall first.

---

## 3. 5-Step Demo Script

### Step 1: Launch and Connect on the Same Wi-Fi
1. On Linux PC:
   - Start LibreShare.
   - Turn the **Receive** switch on (on **Nearby** tab or in **Settings**).
   - Find the PC's IP address using `ip -4 addr` (e.g. `192.168.1.20`).
2. On Android Phone:
   - Open LibreShare.
   - Keep the app open and the screen on.
   - Check under **Nearby devices** on the **Nearby** screen. If the Linux PC appears, skip to Step 2.
   - If multicast discovery is blocked on Wi-Fi:
     - Tap **Add device** in the top app bar.
     - Choose **By IP address**.
     - In **IP address (and port)**, type the PC's address (e.g. `192.168.1.20:53318`).
     - Tap **Look up**, then tap **Add**.

### Step 2: Phone Sends a Photo to Linux (First Contact & Verification)
1. On Android:
   - Tap **Send files**.
   - In the system picker, pick a file or photo (long-press to select, then tap **Select**).
   - On the **Send files** screen, under **Choose a device**, tap the device card (the tap starts sending).
2. Verification:
   - Sender screen shows "Verification code" (six digits, e.g. `482 913`) while waiting for the receiver to compare and accept. *(Verified on the Android emulator.)*
   - Linux PC shows dialog **Incoming transfer** displaying the same 6-digit code under **Verification code**. Read both screens aloud and compare: **Accept** only unlocks once the code is shown, it does not check the match for you. *(Verified for the Android dialog on the emulator; the Linux desktop app was not started in the build container.)*
3. Accept and verify:
   - On Linux PC: click **Accept**.
   - Phone shows progress, then displays completion -> tap **Done**.
   - Verify that the received file in `~/Downloads/LibreShare` is byte-identical (compare with `sha256sum`).

### Step 3: Send Again (Trusted / Pinned Peer)
1. On Android:
   - Tap **Send files**, pick another file, and tap **Select**.
   - Under **Choose a device**, tap the Linux PC device card.
2. Transfer without re-verification:
   - Because the PC is now pinned as a known device, no new verification code is required. *(Covered by the engine tests, "a second send needs no verification code"; not repeated on a device.)*
   - On Linux PC: the **Incoming transfer** dialog appears immediately; click **Accept**.
   - Transfer finishes with status complete -> tap **Done**.

### Step 4: Show the Safety Nets
1. Wrong PIN is rejected:
   - In **Settings**, choose **Fixed**, type a 6-digit PIN and tap **Save**: it shows "PIN configured". A sender with a wrong PIN is refused and sees "That PIN was not accepted." *(Saving verified on the emulator; the wrong-PIN refusal by automated tests only.)*
2. Key-change refusal:
   - If a peer's security key changed, the transfer is refused with a warning banner and no **Accept** button. *(Automated tests only; not shown on a device.)*
3. Identity verification:
   - In **Settings**, **Your fingerprint** displays the 16-hex identity fingerprint in groups of 4 with a copy button. *(Verified on the emulator.)*
4. Stranger refusal:
   - If a device is not in receive mode, connection fails with "Could not reach".
   - If an unexpected transfer arrives, the receiver can tap **Reject** on the **Incoming transfer** dialog.

### Step 5: Demonstration with Windows
1. If the Windows app is built (or using the Docker node from `deploy/install.ps1`):
   - Start the Windows peer on the same Wi-Fi.
   - Add the Windows peer via **Add device** (**By IP address** or **Device link** -> **Add from link**).
   - Tap **Send files**, select a file, tap the Windows device card, and verify completion.

---

## 4. Troubleshooting Table

| Problem / Symptom | Possible Cause | Solution |
|---|---|---|
| Devices cannot discover each other on the network | Wi-Fi AP isolation or router blocking multicast | Connect both devices to the same Wi-Fi network (avoid guest networks). Use **Add device** -> **By IP address** to connect directly. |
| Transfer fails with "Could not reach" | Firewall blocking ports, or **Receive** mode is not active | On Linux, open firewall ports UDP 53318 and TCP 53318-53327 (`sudo firewall-cmd --add-port=53318/udp --add-port=53318-53327/tcp`). Ensure the **Receive** switch is turned on on the receiving device. |
| Transfer dies or stalls after a few seconds on Android | App placed in background or screen turned off | Android blocks background network access after ~5 seconds. Keep the app open and visible in the foreground with the screen on for the whole transfer. |
| Files cannot be opened on Android after receiving | Prototype saved files to an app-internal path | In **Settings** -> **Download folder**, select a public folder under Download, tap **Use this folder**, and tap **Allow**. |
| Connection hangs or fails on restart | Stale connection or port conflict | Verify receiver port with `ss -ltn` on port 53318. Restart the receiver app if needed. |

---

## 5. What this MVP does not do

The following items are deferred from the MVP and preserved in the project roadmap (from `docs/plans/mvp.md` OUT section):

- **Android background receive service (P9)**: The MVP requires keeping the app open in the foreground (keep-screen-on is enabled while visible).
- **Notifications and notification actions**: No push/system notifications or notification action buttons.
- **QR pairing screen and Contacts-only UI**: Supported by core and CLI, but dedicated UI screens and toggles are deferred.
- **Extra Docker end-to-end scenarios (P10)**: Baseline Docker e2e remains active, but extra scenarios are deferred.
- **Windows secure key store**: File-based secret store is used instead of Windows DPAPI/credential store.
- **Increment 4**: Connection ladder, transfer resume across channels, and hashing speed optimizations.
- **Increment 5 & 5b**: Internet tunneling, share link, and reverse proxy.
- **Increment 6**: Free public rendezvous discovery servers.
- **Increment 7**: BLE discovery and Wi-Fi hotspot mode.
- **Polish**: Final UI polish and store packaging.
