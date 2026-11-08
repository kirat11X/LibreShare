# LibreShare Precompiled Builds

Precompiled release builds for LibreShare v1.0.0.

Verify integrity using checksums:
```bash
sha256sum -c SHA256SUMS
```

## Available Packages

### Android APKs
* **Universal (Any Device):** [`libreshare-1.0.0-android-universal.apk`](libreshare-1.0.0-android-universal.apk) (~81 MiB)
* **ARM64-v8a (Modern Phones & Tablets):** [`libreshare-1.0.0-android-arm64-v8a.apk`](libreshare-1.0.0-android-arm64-v8a.apk) (~29 MiB) — *Recommended for Android*
* **ARMv7a (32-bit Devices):** [`libreshare-1.0.0-android-armeabi-v7a.apk`](libreshare-1.0.0-android-armeabi-v7a.apk) (~25 MiB)
* **x86_64 (Emulators / ChromeOS):** [`libreshare-1.0.0-android-x86_64.apk`](libreshare-1.0.0-android-x86_64.apk) (~31 MiB)

#### Android Installation
```bash
adb install -r libreshare-1.0.0-android-arm64-v8a.apk
```
Or transfer the APK to your phone and open it to install (enable "Install unknown apps" when prompted).

---

### Linux x64
* **Bundle Archive:** [`libreshare-1.0.0-linux-x64.tar.gz`](libreshare-1.0.0-linux-x64.tar.gz) (~11.5 MiB)

#### Linux Run Instructions
```bash
tar xzf libreshare-1.0.0-linux-x64.tar.gz
cd libreshare-1.0.0-linux-x64
./libreshare_app
```
*Dependencies: GTK 3 (`libgtk-3-0`), libstdc++, glibc 2.31+.*

---

### Windows x64
* Windows release build is generated via `tools/package_prototype.sh windows` (or `flutter build windows --release`) and uploaded as `libreshare-1.0.0-windows-x64.zip`.
