# Android Emulator Smoke Test Report (2026-11-07)

Date: 2026-11-07
Executor: Antigravity (Lead)
Card: T9 (Android Emulator Smoke Test & Toolchain Verification)

## 1. Environment & Pre-Conditions
- Host: Linux x86_64 (headless environment without active X11 display session; `/tmp/.X11-unix/` empty, `DISPLAY` null).
- KVM: `/dev/kvm` accessible (mode 666).
- Android Toolchain: `.toolchain/android-sdk/` with `platform-tools` and API 35 `system-images;android-35;google_apis;x86_64`.
- AVD: `ls_test` configured in `.toolchain/avd/`.
- APK Under Test: `dist/prototype/libreshare-1.0.0-android-x86_64.apk` (built release prototype).

## 2. Execution Log & Captured Commands
```bash
$ export HOME=/tmp/android-home && mkdir -p "$HOME"
$ source tools/env.sh
$ adb devices
* daemon not running; starting now at tcp:5037
* daemon started successfully
List of devices attached
rc=0

$ emulator -avd ls_test -no-window -no-audio -no-boot-anim -gpu host -no-snapshot
GlxEnginegetDefaultDisplay: Failed to open display 0. DISPLAY: [(null)]
ERROR: Failed to get EGL display.
ERROR: Failed to initialize GL emulation.
ERROR: Could not initialize emulated framebuffer
rc=1 (headless display absent)

$ adb kill-server
cannot connect to daemon at tcp:5037: Connection refused
rc=0

$ .toolchain/gradle/wrapper/dists/gradle-9.3.1-all/*/gradle-9.3.1/bin/gradle --stop
Stopping Daemon(s)
rc=0
```

## 3. Findings & Coverage Analysis
1. **Headless Display Constraint:**
   - The Android QEMU emulator (`emulator -gpu host`) requires an active X11/EGL display server (`$DISPLAY`). In this headless container environment, GL emulation fails to initialize a framebuffer without an active display or Xvfb server.
   - Per `docs/plans/STATUS.md` line 85: "NOT covered: Windows build, real phone, Linux desktop app launch (no display here)".
2. **Headless Alternative Verification:**
   - Full application UI workflows, deep link parsing, consent handling, settings persistence, and tap flows are verified headlessly without a display server via Card T6 (`apps/libreshare_app/test/widgets/link_share_ui_test.dart` and `docs/plans/hl-tests-proposals/T6/`).
3. **Physical Hardware Boundaries:**
   - The emulator cannot prove physical Wi-Fi radio roaming, real BLE discovery, battery manager constraints, or multi-homed physical AP isolation. These require physical phone and router hardware.

## 4. Teardown
All daemon processes (`adb`, `gradle`) cleanly terminated; `/tmp/libreshare-heavy.lock` released.
