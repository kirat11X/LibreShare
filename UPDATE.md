# LibreShare v1.0.1 Release Notes & Patch Details

## Overview

LibreShare **v1.0.1** introduces the **Installable Web Portal (PWA)** for zero-install browser file transfers, ships the new **official branding and multi-platform app icons**, adopts the **Dual-Licensing Model (GNU AGPLv3 + Commercial Rights Reserved)**, and incorporates performance improvements and bugfixes.

---

## 1. Is the Web Portal an "App Kind"?

**Yes, it is built as an installable Progressive Web App (PWA):**

* **Standalone Experience:** It serves a valid Web App Manifest (`/web/manifest.json`) with `display: standalone`. When launched from a device home screen or app launcher, it runs without browser address bars, navigation buttons, or browser chrome—behaving just like a native app.
* **1-Tap Installation on Android & Desktop:** On Android (Chrome, Edge, Samsung Internet) and Desktop (Chrome, Edge, Brave), a **📲 Install App** button appears dynamically in the portal header via the native `beforeinstallprompt` event.
* **1-Tap Installation on iPhone / iPad:** On iOS Safari, the install prompt provides direct, step-by-step guidance:
  $$\text{Share button } (\uparrow) \longrightarrow \text{"Add to Home Screen"}$$
* **Offline Local Wi-Fi Execution:** The entire Single-Page Application (HTML, CSS, JS, SVG assets) is self-contained with **zero CDN dependencies**. It runs completely offline on your local network or phone hotspot without requiring an active internet connection.

---

## 2. Made for Easy Access (App & CLI)

To make accessing and starting the Web Portal seamless across all devices, the following interfaces were added:

### A. In the LibreShare Flutter App
* **Header Shortcut:** A direct globe button (`action-web-portal`) is featured on the `HomeScreen` AppBar for instant navigation.
* **Dedicated Web Portal Screen (`WebPortalScreen`):**
  * **1-Switch Activation:** Toggle the local HTTP web server on/off with one tap.
  * **Instant QR Code:** Renders a high-contrast QR code (`PrettyQrView`). Any phone or tablet camera can scan it to instantly open the portal in their browser and install the PWA.
  * **One-Click URL Copy:** Copy the exact LAN address (e.g. `http://192.168.x.x:53320/web`) to your clipboard.
  * **PIN Security:** Optional PIN authentication to prevent unauthorized devices on public, dorm, or hotel Wi-Fi from uploading or downloading files.
  * **Shared Files Management:** Pick and offer specific files for download to connecting web browsers.
  * **Received Files Stream:** Real-time listing of files uploaded by browser clients with direct **Open Folder** action.
  * **State Management:** Fully reactive architecture provided via `webPortalProvider` in Riverpod.

### B. In the LibreShare CLI
Added the `ls web` command to `packages/libreshare_cli`:

```bash
# Share a directory and optional files to any web browser on your Wi-Fi:
ls web --dir ~/Downloads/LibreShare --share report.pdf photo.jpg --pin 1234
```
* Automatically discovers and announces the active LAN URL on your network.
* Streams upload and download events live to the terminal.
* Fully headless, perfect for home servers, NAS devices, and Raspberry Pis.

---

## 3. Brand Identity & Platform App Icons

* **New App Logo & Iconography:** Integrated the geometric LS paper-plane monogram and branding into all native builds.
* **Multi-Platform Icons:**
  * **Android:** Adaptive mipmaps (`mdpi`, `hdpi`, `xhdpi`, `xxhdpi`, `xxxhdpi`) generated in `res/mipmap-*/ic_launcher.png`.
  * **iOS:** Complete `AppIcon.appiconset` catalog supporting iPhone and iPad resolutions up to 1024x1024.
  * **macOS:** Native `.icns` / `AppIcon.appiconset` supporting Retina 16px to 1024px displays.
  * **Windows:** High-resolution embedded `app_icon.ico` (256, 128, 64, 48, 32, 16 px).
  * **Linux:** High-resolution `libreshare.png` (512x512) desktop icon.
* **In-App Integration:**
  * Desktop `NavigationRail` leading header badge.
  * Settings Screen "About" card featuring the overall logo, version number, and licensing notice.
* **Icon Automation:** Added [`assets/src/generate_app_icons.py`](apps/libreshare_app/assets/src/generate_app_icons.py) for 1-command regeneration.

---

## 4. Dual-Licensing Model Adopted

* **Open-Source (GNU AGPLv3):** Copyleft protection ensuring that any distributed modifications or network deployments must remain free and open source.
* **Commercial Rights Reserved:** All commercial, proprietary, closed-source, OEM, and white-label rights are reserved exclusively by the author. Commercial licenses are required for proprietary embedding or commercial resale.
* **Trademark Protection:** Project name ("LibreShare") and logos are protected trademarks; third-party forks must rebrand.

---

## 5. Artifacts Built in v1.0.1

| Platform | Package | Architecture | Status |
| :--- | :--- | :--- | :--- |
| **Linux** | `libreshare-1.0.1-linux-x64.tar.gz` | x64 | Built & Verified |
| **Android** | `libreshare-1.0.1-android-arm64-v8a.apk` | ARM64 (Modern devices) | Built & Verified |
| **Android** | `libreshare-1.0.1-android-universal.apk` | All ABIs | Built & Verified |
| **Android** | `libreshare-1.0.1-android-armeabi-v7a.apk` | ARMv7 (32-bit legacy) | Built & Verified |
| **Android** | `libreshare-1.0.1-android-x86_64.apk` | x86_64 (Emulators/ChromeOS) | Built & Verified |
| **Windows** | `libreshare-1.0.1-windows-x64.zip` | x64 | Staged for Windows build |
