# Android build toolchain (project-local)

Everything lives under `.toolchain/` (gitignored). Nothing needs sudo, `dnf`, `flutter config`, or
the system Java (25 is too new for Flutter's Gradle). `source tools/env.sh` wires it all up through
environment variables. Set up and proven on 2026-11-04 (Fedora 44, x86_64).

## What is installed

| Path (under `.toolchain/`) | What | Version | Size |
|---|---|---|---|
| `jdk-17/` | Eclipse Temurin JDK | 17.0.21+9 | 319 MB |
| `android-sdk/cmdline-tools/latest/` | Android command-line tools (`sdkmanager`, `avdmanager`, ...) | build 15859902 (sdkmanager 22.0) | 174 MB |
| `android-sdk/platform-tools/` | `adb`, `fastboot` | 37.0.1 | 22 MB |
| `android-sdk/platforms/android-36` | compileSdk / targetSdk 36 (Flutter 3.47.9 default) | rev 2 | part of 265 MB |
| `android-sdk/platforms/android-35` | auto-installed by AGP (a plugin's compileSdk) | rev 2 | (see above) |
| `android-sdk/build-tools/36.0.0` | `aapt2`, `apksigner`, `zipalign`, `d8` | 36.0.0 | 147 MB |
| `android-sdk/ndk/28.2.13676358` | NDK r28c, `flutter.ndkVersion` (strip, native plugins) | 28.2.13676358 | 2.2 GB |
| `android-sdk/cmake/3.22.1` | auto-installed by AGP for the NDK build step | 3.22.1 | 60 MB |
| `gradle/` | `GRADLE_USER_HOME`: Gradle 9.3.1 distribution, AGP 9.1.0, Kotlin 2.4.0, Maven caches | 9.3.1 | 4.7 GB |

Total about 8.2 GB. Project pins that drive this: `android/settings.gradle.kts` (AGP 9.1.0,
Kotlin 2.4.0), `android/gradle/wrapper/gradle-wrapper.properties` (Gradle 9.3.1),
`flutter.compileSdkVersion = 36`, `minSdkVersion = 24`, `targetSdkVersion = 36`,
`ndkVersion = 28.2.13676358` (all from Flutter 3.47.9's `FlutterExtension.kt`).

## Daily use

```bash
source tools/env.sh                       # idempotent; paths resolve relative to the script
cd apps/libreshare_app
flock /tmp/libreshare-flutter-build.lock flutter build apk --debug     # -> build/app/outputs/flutter-apk/app-debug.apk
flock /tmp/libreshare-flutter-build.lock flutter build apk --release   # -> .../app-release.apk
# smaller per-ABI release APKs (arm64-v8a is what phones need):
flock /tmp/libreshare-flutter-build.lock flutter build apk --release --split-per-abi
```

Always take the `flock`: other agents share the Flutter build tree. First build downloads about 1.5 GB
(Gradle dists, Maven artifacts, NDK) and takes about 10 minutes; later builds are much faster.

The release APK is signed with the **debug key** (`signingConfig = signingConfigs.getByName("debug")` in
`android/app/build.gradle.kts`). That is fine for sideloading a prototype, not for the Play Store. No
keystore exists or is committed; generate one only when a real release is wanted and keep it out of git
(`android/.gitignore` already ignores `key.properties`, `*.jks`, `*.keystore`).

## Reinstall from scratch

```bash
cd "<repo root>"
mkdir -p .toolchain/jdk-17 .toolchain/android-sdk/cmdline-tools && T=$(mktemp -d) && cd "$T"

# 1. JDK 17 (Temurin). Expected SHA-256 comes from the Adoptium API:
#    curl -s 'https://api.adoptium.net/v3/assets/latest/17/hotspot?architecture=x64&image_type=jdk&os=linux&vendor=eclipse'
curl -L -o jdk17.tar.gz 'https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse'
sha256sum jdk17.tar.gz   # 17.0.21+9: 8b9b611d917e3dfd8419d3566b5949226f69b052fed7e109c1368add1dfe8711
tar -xzf jdk17.tar.gz -C "<repo root>/.toolchain/jdk-17" --strip-components=1

# 2. Android command-line tools. Name and SHA-256 are published on https://developer.android.com/studio
curl -L -O https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip
sha256sum commandlinetools-linux-15859902_latest.zip
#   4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
unzip -q commandlinetools-linux-15859902_latest.zip
mv cmdline-tools "<repo root>/.toolchain/android-sdk/cmdline-tools/latest"

# 3. SDK components. This accepts the Android SDK licences (needed to build for Android at all).
cd "<repo root>" && source tools/env.sh
yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses
sdkmanager --sdk_root="$ANDROID_HOME" "platform-tools" "platforms;android-36" "platforms;android-35" \
  "build-tools;36.0.0" "ndk;28.2.13676358" "cmake;3.22.1"
```

If the numbers have moved on, take the current name and checksum from the two pages above; the
Gradle build installs any component it is missing on its own (licences are already accepted), so a
shorter `sdkmanager` list also works, it just moves the download into the first build.

## Gotchas found while setting this up

1. **Spaces in the repo path break `flutter doctor` (Android toolchain shows `[!]`).** This repo lives in
   `.../Software Engineering LibreShare`. Flutter hard-wires an error for an SDK path containing spaces
   ("causes problems with NDK tools") and then skips the licence and Java checks. The builds themselves
   succeed with the spaced path. To get a green doctor, give the SDK a space-free alias. `tools/env.sh`
   uses it automatically when it exists:
   ```bash
   ln -s "$PWD/.toolchain/android-sdk" "$HOME/.libreshare-android-sdk"   # opt-in; the only thing outside the repo
   ```
   (`LS_ANDROID_SDK_LINK=/some/space-free/link` overrides the location.) Verified: with the alias,
   doctor reports `[✓] Android toolchain`, Temurin 17.0.21+9 and "All Android licenses accepted."
   Also, some SDK shell wrappers (`apkanalyzer`) break on spaces in the real path; use `aapt2 dump badging`
   and `aapt2 dump xmltree --file AndroidManifest.xml` instead.
2. **Gradle wrapper download hangs ("Connection timed out").** `services.gradle.org` redirects to
   `release-assets.githubusercontent.com`, which resolves to four IPv4 addresses; one of them
   (185.199.109.133) times out from this network and the wrapper's Java client does not fall back to the
   next address (curl does). Fix: download the zip with curl, verify it against
   `https://services.gradle.org/distributions/gradle-9.3.1-all.zip.sha256`
   (`17f277867f6914d61b1aa02efab1ba7bb439ad652ca485cd8ca6842fccec6e43`), and put it where the wrapper looks:
   ```bash
   D=.toolchain/gradle/wrapper/dists/gradle-9.3.1-all/9ot9r568e8zfvvd4mn8rbu1j0   # hash of the distributionUrl
   mkdir -p $D && cp gradle-9.3.1-all.zip $D/ && (cd $D && unzip -q gradle-9.3.1-all.zip && touch gradle-9.3.1-all.zip.ok)
   ```
   Maven Central and Google Maven downloads were not affected.
3. **Gradle daemon memory.** `android/gradle.properties` sets `-Xmx8G`; the daemon stays alive after a build.
   Free the RAM with `cd apps/libreshare_app/android && ./gradlew --stop`.
4. **APK size.** Debug is about 198 MB and release about 81 MB because both are fat APKs (arm64-v8a,
   armeabi-v7a, x86_64). `mobile_scanner` bundles the ML Kit barcode models and native decoder
   (`libbarhopper_v3.so`, about 5 MB per ABI) and `tray_manager` 0.8.2 and `window_manager` 0.6.0 (via `nativeapi_flutter`/`cnativeapi`) ship
   `libcnativeapi.so` (about 2 MB per ABI) although they are desktop-only. `--split-per-abi` gives one APK per ABI.
   `mobile_scanner` also pulls in Google Play Services client components (`GoogleApiActivity`,
   Firebase datatransport, `MlKitInitProvider`) as seen in the merged manifest; relevant if an F-Droid
   style build is ever wanted.

## Emulator / device

None was installed and the APK has **not been run** (no device here). `/dev/kvm` exists and is
read/write for the user, so an emulator is possible later:
`sdkmanager "emulator" "system-images;android-36;google_apis;x86_64"` (both package ids exist in the
current repository listing) then `avdmanager create avd ...`; expect well over 1 GB more. With a physical phone use `adb install -r app-release.apk` (USB debugging on).

## Remove

```bash
rm -rf .toolchain/jdk-17 .toolchain/android-sdk .toolchain/gradle
rm -f "$HOME/.libreshare-android-sdk"            # only if you created the alias
```
`apps/libreshare_app/android/local.properties` and `.gradle/` are generated and gitignored.
