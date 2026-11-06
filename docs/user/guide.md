# LibreShare User Guide

Welcome to LibreShare! LibreShare is a free, open-source application designed to let you quickly and securely transfer files between your personal devices—such as your Android phone, Linux desktop, or Windows PC—without uploading anything to the internet or relying on third-party servers.

---

## 1. Privacy Guarantees

Before using LibreShare, here is what you should know about how your data is handled:

- **Direct Peer-to-Peer Transfers:** Files move directly across your local Wi-Fi or Ethernet network from one device to another.
- **No Cloud Servers:** Your photos, documents, and videos never travel through a remote server or external cloud storage.
- **Zero Telemetry and Tracking:** LibreShare contains no usage analytics, no crash reporters, no tracking IDs, and no advertising frameworks.
- **No Account Required:** You do not need to register an email address, create a password, or sign in to any service.
- **Data Stays on Your Devices:** When transfers finish, only you and the recipient hold copies of the transferred files.

---

## 2. Installation per Platform

### Linux (Tarball Archive)
1. Download the Linux package `libreshare-1.0.0-linux-x64.tar.gz`.
2. Open a terminal, extract the archive, and launch LibreShare:
   ```bash
   tar xzf libreshare-1.0.0-linux-x64.tar.gz
   cd libreshare-1.0.0-linux-x64
   ./libreshare_app
   ```
3. **Prerequisite:** LibreShare requires GTK 3 (installed by default on Ubuntu, Fedora, Debian, and most desktop distributions).
4. **Firewall Notice:** If your Linux system has an active firewall, allow LibreShare to communicate on your local network:
   - On Fedora / RHEL (`firewalld`):
     ```bash
     sudo firewall-cmd --permanent --add-port=53318-53327/tcp --add-port=53318/udp && sudo firewall-cmd --reload
     ```
   - On Ubuntu / Debian (`ufw`):
     ```bash
     sudo ufw allow 53318:53327/tcp && sudo ufw allow 53318/udp
     ```

### Windows (Zip Archive)
> [!WARNING]
> **[NOT VERIFIED: no Windows build exists yet; code has never been compiled or run for Windows (docs/test-reports/mvp-acceptance-secure.md:13, 75)]**. The instructions below describe the intended setup once a Windows build is produced.

1. Download the Windows application zip package `libreshare-1.0.0-windows-x64.zip`.
2. Extract the archive into a folder of your choice (such as your user directory).
3. Open the extracted folder and run `libreshare_app.exe` to start the app.
4. **Windows Firewall Prompt:** The first time LibreShare opens or turns on receiving, Windows Firewall will display a prompt asking for permission. Check the box for private networks (such as your home or work network) and allow access.

### Android (APK)
> [!NOTE]
> Tested on an Android x86_64 emulator (API 35); **[NOT VERIFIED: no real-phone test exists yet (docs/test-reports/mvp-acceptance-secure.md:13, 76)]**.

1. Download the Android installer package `libreshare-1.0.0-android-arm64-v8a.apk` (recommended for modern Android phones and tablets) or `libreshare-1.0.0-android-universal.apk` for older hardware.
2. Tap the downloaded APK file in your phone's browser or file manager.
3. If prompted by Android about installing unknown apps from this source, enable the permission in system settings, then complete the installation.
4. **Important note:** Install only one flavor of the APK. If you ever need to switch between the universal and ARM64 packages, you must uninstall the existing one first.

---

## 3. First Transfer Walkthrough

Follow these simple steps to send your first file between two devices:

### Step 1: Connect Both Devices to the Same Network
Make sure both your sending device (e.g., your Android phone) and your receiving device (e.g., your laptop) are connected to the exact same Wi-Fi router or local network.

### Step 2: Open LibreShare and Turn On Receive
By default, LibreShare does not broadcast your device to the network until you tell it to:
1. On the receiving device, open LibreShare to the main **Nearby** screen.
2. Turn on the **Receive** switch at the top of the screen. You can choose a duration such as **15 min**, **1 h**, **6 h**, or **Always**.
3. **Android Storage Prompt:** The very first time you turn on **Receive** on Android, LibreShare displays a dialog titled **Where should received files go?**. Tap **Choose a folder** and select a public folder (like your device's `Downloads` directory) so that gallery and file manager apps can see your received files. (Tapping **Keep default** stores files in app-private storage).

[SCREENSHOT: Main Nearby screen showing the Receive card and duration choices]

### Step 3: Pick the Files to Send
1. On the sending device, open LibreShare and tap the **Send files** button (the floating button at the bottom right).
2. The file browser opens. Select the file or photo you want to share (long-press on Android to select multiple items), then tap **Select**.
3. You can review your selected files or tap **Add more** to include additional documents.

[SCREENSHOT: Send files screen showing selected items and Choose a device header]

### Step 4: Choose the Recipient Device
1. Under the **Choose a device** list, look for your receiving device under **Nearby devices**.
2. **Tap the device card** for the receiver. Tapping the card immediately initiates the transfer.
3. *(If the device does not appear automatically due to Wi-Fi router restrictions, tap **Add device** in the top bar to connect directly—see the Troubleshooting section below).*

### Step 5: Verify the 6-Digit Code and Accept
1. Because this is the first time these two devices have connected, both devices will present a 6-digit **Verification code** (verified: `apps/libreshare_app/lib/screens/transfer_screen.dart:295`, `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:270`, and confirmed in emulator smoke `docs/test-reports/mvp-acceptance-secure.md:54-55`).
2. Compare the 6 digits shown on both screens (for example, `482 913`). Verify that they are identical (verified: `packages/libreshare_core/lib/src/security/sas.dart:87-111` calculates the identical 6-digit code for both peers; confirmed on emulator in `docs/test-reports/mvp-acceptance-secure.md:9, 54-55`).
3. On the receiving device, look at the **Incoming transfer** dialog and click or tap **Accept** (verified: `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:341-347`; **Accept** enables once the verification code is calculated, but does not auto-check matches—users must verify digits themselves as noted in `docs/dev/demo-mvp.md:12`).
4. Both devices will display progress bars as the file chunks transfer. When finished, tap **Done**.

[SCREENSHOT: Incoming transfer dialog showing Verification code, file list, and Accept button]

---

## 4. The 6-Digit Verification Code Explained

When you connect two devices for the first time, LibreShare displays a 6-digit **Verification code** (known in security terminology as a *Short Authentication String* or *SAS*; verified: `packages/libreshare_core/lib/src/security/sas.dart:87-111`, `SECURITY.md:38`).

### Why Does It Exist?
When you send files across Wi-Fi, LibreShare automatically encrypts the connection using TLS 1.3 with a persistent 10-year self-signed ECDSA P-256 certificate (verified: `packages/libreshare_core/lib/src/security/cert_factory.dart:431`, `SECURITY.md:36`, `docs/test-reports/mvp-acceptance-secure.md:9`). However, encryption alone cannot guarantee that an attacker or rogue device on the same public Wi-Fi network isn't sitting in the middle intercepting the communication (verified: `SECURITY.md:38`, `packages/libreshare_core/lib/src/security/sas.dart:1-12`).

The 6-digit verification code is mathematically calculated from the unique cryptographic keys and session nonces of both devices for this specific session (verified: `packages/libreshare_core/lib/src/security/sas.dart:6-7, 101-110`).
- If both devices display the exact same 6 digits, it proves that the connection is direct, private, and uncompromised (verified: `packages/libreshare_core/lib/src/security/sas.dart:87-111`, `docs/test-reports/mvp-acceptance-secure.md:9`).
- If an unauthorized party were attempting to intercept the connection, the codes on the two screens would not match (verified: commit-reveal exchange in `packages/libreshare_core/lib/src/security/sas.dart:3-12`, `SECURITY.md:38`).

### How to Use It in Practice
- **It is NOT a password you type in:** You do not need to type the verification code anywhere (verified: `apps/libreshare_app/lib/screens/transfer_screen.dart:295`, `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:275-286`, `docs/dev/demo-mvp.md:12`).
- **Read it out loud or compare screens:** When sending files to a nearby friend or between devices, glance at the two screens or read the digits aloud (verified in UI strings: `apps/libreshare_app/lib/screens/transfer_screen.dart:295`, `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:284`, and tested on emulator in `docs/test-reports/mvp-acceptance-secure.md:54-55`; **[NOT VERIFIED: no real-phone test and no Windows build exists yet (docs/test-reports/mvp-acceptance-secure.md:13, 75, 76)]**).
- **Accept only if the codes match:** On the receiving device, the **Accept** button is safely enabled once the code is calculated (verified: `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:341-347`, `docs/dev/demo-mvp.md:12`). If the code does not match, tap **Reject** (verified: `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:335-339`).
- **One-time check:** Once you accept a transfer from a device, LibreShare remembers that device as trusted so you will not need to re-verify the digits on future transfers (verified: `packages/libreshare_core/lib/src/transfer/file_receiver.dart:268-278`, `docs/dev/demo-mvp.md:92`).

---

## 5. PIN Protection

If you frequently share files on a shared network (like a college dorm, shared office, or household Wi-Fi), you might not want other users sending transfer prompts to your screen unexpectedly. LibreShare includes optional PIN protection configured in **Settings** (verified: `apps/libreshare_app/lib/screens/settings_screen.dart:601-703`, `SECURITY.md:39`).

In the LibreShare app, tap the **Settings** tab in the navigation bar and find the PIN setting card (verified: `apps/libreshare_app/lib/screens/settings_screen.dart:607-618`):

- **Off** (Default): Anyone on your local network who sees your device can send you a transfer request. You still retain full control and must manually click **Accept** on every incoming transfer (verified: default policy in `packages/libreshare_core/lib/src/security/pin_guard.dart:37`; manual consent in `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:341-347`).
- **Fixed**: You choose a permanent **6-digit PIN** and tap **Save** (verified: `apps/libreshare_app/lib/screens/settings_screen.dart:532-585, 685`, confirmed on emulator in `docs/test-reports/mvp-acceptance-secure.md:63`). Whenever any sender attempts to send you files, LibreShare asks them to enter this PIN first before your device will even ring or show the transfer prompt (verified in code and automated tests: `packages/libreshare_core/lib/src/security/pin_guard.dart:113-115`, `apps/libreshare_app/lib/screens/transfer_screen.dart:184-223`, `docs/dev/demo-mvp.md:98`). You can tap **Change** anytime to update your fixed PIN (verified: `apps/libreshare_app/lib/screens/settings_screen.dart:689-696`).
- **New each time**: Each time you turn on **Receive**, LibreShare generates a brand-new random 6-digit PIN and displays it on your **Receive** card (for example, `PIN: 582104`; verified: `apps/libreshare_app/lib/widgets/receive_card.dart:44-48, 86-92`, `packages/libreshare_core/lib/src/security/pin_guard.dart:68-69`). Senders must enter this temporary PIN to reach you (verified: `packages/libreshare_core/lib/src/security/pin_guard.dart:96-125`, `apps/libreshare_app/lib/screens/transfer_screen.dart:184-223`). When receiving turns off, the PIN expires (verified: `apps/libreshare_app/lib/widgets/receive_card.dart:43-48`, `packages/libreshare_core/lib/src/security/pin_guard.dart:9`).

### PIN Security Rules & Protection Window
- **Brute-Force Protection Window:** If an unauthorized device attempts to guess your PIN, 5 consecutive wrong PIN attempts from one IP within 10 minutes will automatically lock that device out for a 10-minute window (verified: `packages/libreshare_core/lib/src/security/pin_guard.dart:6-9, 23-25, 127-135`). Additionally, 25 strikes across all addresses lock PIN checks globally for 10 minutes and rotate the PIN (`pin_guard.dart:7-8, 137-142`). All lockout counters live strictly in memory and reset when the app restarts (verified: `packages/libreshare_core/lib/src/security/pin_guard.dart:9`, `docs/test-reports/mvp-acceptance-secure.md:79`).
- **Trusted Contacts Bypass:** Devices that you have already paired with and saved in **Contacts** are automatically exempt from PIN entry and can connect directly without re-typing the PIN (verified: `packages/libreshare_core/lib/src/security/pin_guard.dart:101`, `packages/libreshare_core/lib/src/transfer/file_receiver.dart:258-261`).

[SCREENSHOT: Settings screen showing PIN mode buttons: Off, Fixed, and New each time]

---

## 6. Contacts and Trusted Devices

LibreShare automatically manages trusted connections using cryptographic device keys (verified: persistent ECDSA P-256 certificate valid for 10 years / 3650 days, not ephemeral, `packages/libreshare_core/lib/src/security/cert_factory.dart:431`, `packages/libreshare_core/lib/src/storage/credential_store.dart:15`, `SECURITY.md:36`):

### How Device Pinning Works
- **First Contact:** A device you have never interacted with before is labeled as a **New device** (verified: `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:50`, confirmed on emulator in `docs/test-reports/mvp-acceptance-secure.md:55`).
- **Automatic Pinning:** When you verify the 6-digit code and accept a transfer, LibreShare "pins" that device's identity key (verified: Trust-On-First-Use in `packages/libreshare_core/lib/src/transfer/file_receiver.dart:587-593`, `SECURITY.md:37`). Subsequent transfers label the peer as a **Known device** or **Trusted contact**, and the transfer prompt appears immediately without prompting for digit comparison (verified: `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:51-52`, `packages/libreshare_core/lib/src/transfer/file_receiver.dart:268-278`, `docs/dev/demo-mvp.md:92`).

### The Security Key Changed Warning
If a device you previously trusted attempts to connect to you, but its underlying cryptographic identity key has changed, LibreShare treats this as a potential security risk (verified in code and automated tests: `packages/libreshare_core/lib/src/storage/credential_store.dart:7-12`, `SECURITY.md:37`, `docs/test-reports/mvp-acceptance-secure.md:82`; not tested on physical device):
- An alert banner is displayed: *"This device's security key changed. It may be a new phone, or someone pretending to be it."* (verified: `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:156`, automated tests `docs/test-reports/mvp-acceptance-secure.md:82`).
- The **Accept** button is deliberately removed to protect you against spoofing attacks (verified: `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:340`, `docs/dev/demo-mvp.md:14`).
- You can tap **Reject** or tap **Open Contacts** to inspect your trusted list (verified: `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:166-174, 335-339`). (If your friend simply reinstalled LibreShare or bought a new phone, remove their old record in Contacts and add them anew; verified: `apps/libreshare_app/lib/screens/settings_screen.dart:790-801`).

### Managing Contacts
Under **Settings** -> **Contacts**, you can view all devices that have paired with you (verified: `apps/libreshare_app/lib/screens/settings_screen.dart:724-785`):
- **Remove:** Tapping **Remove** deletes the stored identity for that device. If they contact you again, they will be treated as a **New device** requiring standard verification (verified: `apps/libreshare_app/lib/screens/settings_screen.dart:795`, `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1238`).
- **Block:** Tapping **Block** adds the device's key to your blocked list. LibreShare will silently decline all future connection attempts from that device (verified: `apps/libreshare_app/lib/screens/settings_screen.dart:805`, `packages/libreshare_core/lib/src/storage/trust_store.dart:95-105`).

[SCREENSHOT: Contacts section in Settings with trust badges, Remove, and Block buttons]

---

## 7. Where Files Go (Download Folders)

Received files are saved into dedicated folders depending on your operating system:

| Platform | Default Download Location | How to Change It |
|---|---|---|
| **Linux** | `~/Downloads/LibreShare` | In **Settings**, tap **Download folder** to choose a new location, or tap **Use the default folder** to reset. |
| **Windows** | `Downloads\LibreShare` inside your user profile (e.g., `C:\Users\<Username>\Downloads\LibreShare`) | In **Settings**, tap **Download folder** to browse and select any folder or drive. |
| **Android** | `Downloads/LibreShare` in public storage (if selected via **Choose a folder**) | Open **Settings** -> tap **Download folder** -> select your desired folder. |

> **Android Storage Note:** If you selected **Keep default** during the initial setup prompt, Android stores files in an isolated app-private directory (`Android/data/dev.libreshare.libreshare_app/...`). Normal gallery and media apps cannot browse this directory. To make your files accessible to other apps, go to **Settings** -> **Download folder** and pick a folder in your main `Downloads` directory.

> **Safe File Naming:** If you receive a file with a name that already exists in your download folder (such as `photo.jpg`), LibreShare automatically saves the new file as `photo (1).jpg`. Existing files are never overwritten or replaced.

---

## 8. Troubleshooting: "Why Can't My Phone See My PC?"

If devices fail to discover each other automatically, work through these common causes:

### 1. Wi-Fi Router AP / Client Isolation (Guest Networks)
- **The Issue:** Many public Wi-Fi networks (hotels, cafes, airports, university dorms) and guest Wi-Fi networks on home routers have AP (Access Point) Isolation or Client Isolation enabled. This router setting deliberately prevents connected wireless devices from communicating with one another.
- **The Solution:**
  - Connect both devices to the primary (non-guest) Wi-Fi network.
  - Or turn on your phone's personal Wi-Fi Hotspot and connect your laptop to the hotspot.
  - Or connect manually using IP addresses (see item 3 below).

### 2. The Receive Switch is Turned Off
- **The Issue:** To preserve battery and protect privacy, LibreShare does not broadcast your device continuously.
- **The Solution:** Ensure the receiving device has the app open with the **Receive** switch turned ON.

### 3. Different Subnets or Multicast Blocked (Add Manually)
- **The Issue:** Some routers block multicast/mDNS discovery packets or place 2.4 GHz and 5 GHz Wi-Fi bands on different internal subnets.
- **The Solution:** Connect directly using IP address:
  1. On the receiving device, open **Settings** to see its IP address under network settings, or check your system Wi-Fi details (e.g., `192.168.1.45`).
  2. On the sending device, tap **Add device** in the top navigation bar.
  3. Select **By IP address**, enter the address into **IP address (and port)** (e.g., `192.168.1.45:53318`), tap **Look up**, and tap **Add**.
  4. Alternatively, tap **My QR code** on the receiver and tap **Scan QR code** (or **Add from link**) on the sender.

[SCREENSHOT: Add device screen showing By IP address and By link or QR code tabs]

### 4. Firewall Blocking LibreShare on PC
- **The Issue:** Your PC's firewall may be blocking incoming connections on LibreShare's listening ports (UDP 53318 and TCP ports 53318–53327).
- **The Solution:**
  - **Windows:** Open Windows Defender Firewall settings, find LibreShare, and verify that it has checkmarks allowed for private networks.
  - **Linux:** In LibreShare, navigate to **Settings** -> expand **Can't see devices?**, copy the suggested firewall command for `ufw` or `firewalld`, and run it in your terminal. You can also tap **Scan the network now** to re-test network visibility.

### 5. App Placed in Background on Android
- **The Issue:** Android's operating system strictly suspends network access for background apps after approximately 5 seconds to conserve battery life.
- **The Solution:** Keep the LibreShare app open on your screen with the display on while transfers are taking place.

---

## 9. Five Common Gotchas for New Users

Here are the top five places where new users occasionally get stuck and how to resolve them:

1. **"The app is open on both devices, but the list says 'No devices found yet'."**
   - *Fix:* Check the **Receive** switch! Unlike Bluetooth apps that run background daemons, LibreShare's receiver must have **Receive** toggled on. If discovery packets are blocked by your router, tap **Add device** to connect by IP.
2. **"I tapped a device to send, but it's stuck on 'Waiting for ... to accept'."**
   - *Fix:* Look at the receiving device! Transfers do not start automatically; the receiving person must tap **Accept** on the **Incoming transfer** dialog. If 120 seconds elapse without action, the request declines automatically (`apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:35`). If the receiver has enabled PIN protection, you must first enter their 6-digit PIN on your screen before the incoming prompt will appear on their device (verified: `apps/libreshare_app/lib/screens/transfer_screen.dart:184-223`, `packages/libreshare_core/lib/src/security/pin_guard.dart:113-115`).
3. **"The transfer suddenly halted or failed midway."**
   - *Fix:* Ensure neither device went to sleep. If an Android phone's screen turns off or you switch to another app, Android pauses the network connection. Keep the app open until the transfer completes.
4. **"I received photos on my Android phone, but they don't show up in Google Photos or my Gallery."**
   - *Fix:* If you tapped **Keep default** when installing, files are in Android's private app sandbox. Go to **Settings** -> **Download folder**, and choose a folder inside your public `Downloads` directory.
5. **"Do I have to type the 6-digit verification code into my phone?"**
   - *Fix:* No! The 6-digit **Verification code** is for visual comparison only (verified: `packages/libreshare_core/lib/src/security/sas.dart:87-111`, `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:275-286`). Do not mistake it for a PIN (verified: `SECURITY.md:38-39`, `packages/libreshare_core/lib/src/security/pin_guard.dart:1-12`). If you see `482 913` on the sender and `482 913` on the receiver, simply tap **Accept** (verified: `apps/libreshare_app/lib/widgets/incoming_transfer_dialog.dart:341-347`, `docs/test-reports/mvp-acceptance-secure.md:54-55`). (You only type a number if you specifically enabled a **6-digit PIN** in Settings; verified: `apps/libreshare_app/lib/screens/transfer_screen.dart:184-223`, `apps/libreshare_app/lib/screens/settings_screen.dart:607-679`).

---

## 10. Known Limits

To set honest expectations, here are the current boundaries of the MVP release:

- **Same Local Network Only:** Both devices must be connected to the same Wi-Fi network or local LAN subnet. Internet link-sharing and remote relay servers are planned for future updates.
- **Foreground Operation Required on Android:** Android devices must keep the app active on screen with the display on during transfers. (An ongoing background service is planned for post-MVP).
- **No Windows Build Yet:** The Windows build has never been compiled or run (`docs/test-reports/mvp-acceptance-secure.md:13, 75`); no Windows zip package exists yet.
- **No Real-Phone Verification Yet:** Testing has been performed on the Android x86_64 emulator only (`docs/test-reports/mvp-acceptance-secure.md:13, 76`), not on physical phone hardware.
- **Transfer Speeds:** Measured transfer speed is approximately 18–19 MiB/s on loopback transfers (17.9 MiB/s measured in `docs/test-reports/mvp-acceptance-secure.md:24`). File transfers utilize secure SHA-256 chunk-by-chunk verification to ensure files arrive without corruption. Optimization toward the 300 MB/s target is scheduled for Increment 4.

---

## 11. Uninstallation Instructions per Platform

If you ever wish to remove LibreShare from your device:

### Linux
1. Delete the extracted application folder:
   ```bash
   rm -rf libreshare-1.0.0-linux-x64
   ```
2. *(Optional)* Remove user configuration and identity keys:
   ```bash
   rm -rf ~/.local/share/dev.libreshare.libreshare_app
   ```
3. *Note:* Any files you previously received in `~/Downloads/LibreShare` are your personal files and remain untouched.

### Windows
1. Delete the folder where you unpacked `libreshare-1.0.0-windows-x64.zip`.
2. *(Optional)* Remove user configuration and stored settings by deleting the folder:
   `%APPDATA%\dev.libreshare.libreshare_app` (or `%LOCALAPPDATA%\dev.libreshare.libreshare_app`).
3. If you enabled **Start LibreShare when I sign in**, disable it in Windows system startup settings before deleting the folder.
4. *Note:* Received files in `Downloads\LibreShare` remain safely on your computer.

### Android
1. Locate the LibreShare icon on your home screen or app drawer.
2. Long-press the icon, tap app info or drag to uninstall, and confirm.
3. *Note:* If you selected a public download folder (such as `Downloads/LibreShare`), all files you received remain intact in your Downloads folder.

---

For technical architecture details, protocol specifications, or reporting issues, please refer to the project [README](../../README.md) and the [LICENSE](../../LICENSE).
