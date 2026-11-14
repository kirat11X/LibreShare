# LibreShare Precompiled Builds

Precompiled release builds for LibreShare.

Verify integrity using checksums:
```bash
sha256sum -c SHA256SUMS-1.0.1
```

## Available Packages (v1.0.1)

### Android APKs
* **ARM64-v8a (Modern Phones & Tablets):** [`libreshare-1.0.1-android-arm64-v8a.apk`](libreshare-1.0.1-android-arm64-v8a.apk) (~31 MiB) — *Recommended for Android*
* **Universal (All Architectures):** [`libreshare-1.0.1-android-universal.apk`](libreshare-1.0.1-android-universal.apk) (~83 MiB)
* **ARMv7a (32-bit Legacy):** [`libreshare-1.0.1-android-armeabi-v7a.apk`](libreshare-1.0.1-android-armeabi-v7a.apk) (~27 MiB)
* **x86_64 (Emulators / ChromeOS):** [`libreshare-1.0.1-android-x86_64.apk`](libreshare-1.0.1-android-x86_64.apk) (~34 MiB)

#### Android Installation
```bash
adb install -r libreshare-1.0.1-android-arm64-v8a.apk
```
Or transfer the APK to your device and open it to install (enable "Install unknown apps" when prompted).

---

### Linux x64
* **Bundle Archive:** [`libreshare-1.0.1-linux-x64.tar.gz`](libreshare-1.0.1-linux-x64.tar.gz) (~13 MiB)

#### Linux Run Instructions
```bash
tar xzf libreshare-1.0.1-linux-x64.tar.gz
cd libreshare-1.0.1-linux-x64
./libreshare_app
```
*Dependencies: GTK 3 (`libgtk-3-0`), libstdc++, glibc 2.31+.*

---

### Windows x64
* **Package:** `libreshare-1.0.1-windows-x64.zip` (Build with `package-windows.ps1` or download v1.0.0 from GitHub Releases).

#### Windows Build / Run Instructions
To build from source on a Windows host with PowerShell:
```powershell
powershell -ExecutionPolicy Bypass -File tools\release\package-windows.ps1
```
Extract the generated zip and launch `libreshare_app.exe`.

---

### macOS & iOS
Available on the [Official GitHub Releases Page](https://github.com/kirat11X/LibreShare/releases).
