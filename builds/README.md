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

---

### macOS (Apple Silicon & Intel)
* **Application Archive:** `libreshare-1.0.0-macos.zip` (containing `LibreShare.app`)

#### macOS Run Instructions
1. Unzip `libreshare-1.0.0-macos.zip`.
2. Move `LibreShare.app` to your `/Applications` folder.
3. If macOS blocks opening due to Gatekeeper (unnotarized developer build):
   - Right-click `LibreShare.app` and choose **Open**, then click **Open** in the dialog.
   - Or run in Terminal:
     ```bash
     xattr -cr /Applications/LibreShare.app
     ```
4. To build locally on a Mac (requires Xcode):
   ```bash
   tools/release/package-macos.sh
   ```

---

### iOS (iPhone & iPad)
* **IPA Package:** `libreshare-1.0.0-ios.ipa` (unsigned release IPA)

#### iOS Installation (Sideloading)
1. **Using AltStore / SideStore**:
   - Open AltStore on your iPhone.
   - Tap `+` and select `libreshare-1.0.0-ios.ipa` to sign and install with your Apple ID.
2. **Using Sideloadly**:
   - Connect your iPhone to your Mac via USB.
   - Drag `libreshare-1.0.0-ios.ipa` into Sideloadly and enter your Apple ID to sign and install.
3. **Using TrollStore (iOS 14.0–17.0)**:
   - Direct install without 7-day revokes.
4. To build locally on a Mac (requires Xcode):
   ```bash
   tools/release/package-ios.sh
   ```
