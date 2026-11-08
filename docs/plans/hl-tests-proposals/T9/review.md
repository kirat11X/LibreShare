# Independent Review: Card T9 (Android Emulator Smoke Test & Toolchain Verification)

Reviewer: Antigravity Verifier (Independent Quality Audit)
Date: 2026-11-07
Card: T9 (`docs/plans/hl-tests-proposals/T9/`)
Target: `tools/android_emulator_smoke.sh` & `docs/test-reports/android-smoke-20261107.md`

---

## 1. Scope & Execution Analysis
Card T9 executes the Android prototype APK smoke test harness in accordance with `docs/plans/GEMINI_NEXT_STEPS.md` line 37 and `docs/plans/HANDOFF.md` section 3:
- Inspects `/dev/kvm` and Android SDK / API 35 image availability.
- Attempts headless emulator boot under `flock -o /tmp/libreshare-heavy.lock`.
- Confirms emulator GL failure reason (`DISPLAY: [(null)]`, headless environment missing X11/EGL display server).
- Enforces strict daemon teardown (`adb kill-server`, `gradle --stop`).
- References Card T6 (`docs/plans/hl-tests-proposals/T6/`) for full headless app flow verification.

---

## 2. Test Verification Table vs Spec

| Requirement | Test / Verification Step | Expected | Observed | Status |
|---|---|---|---|---|
| KVM Acceleration | `test -r /dev/kvm -a -w /dev/kvm` | rw access | `crw-rw-rw-` mode | PASS |
| Android Toolchain | Check `.toolchain/android-sdk` | SDK 35 & emulator present | Found API 35 image | PASS |
| Prototype Artifact | Check `dist/prototype/*.apk` | x86_64 APK exists | Found x86_64 release APK | PASS |
| Daemon Hygiene | `adb kill-server && gradle --stop` | Clean teardown, 0 lock leak | Daemons killed, rc=0 | PASS |
| Headless App Flows | Card T6 widget test suite | All 8 app scenarios pass | 8/8 pass rc=0 | PASS |

---

## 3. Mutation Table

| # | Mutation Description | Target | Expected Red Test | Observed Result | Verdict |
|---|---|---|---|---|---|
| **M1** | Point smoke script to non-existent APK | `tools/android_emulator_smoke.sh` line 25 | Script aborts immediately | `APK not found` rc=2 | **KILLED** |
| **M2** | Corrupt AVD name (`ls_test_invalid`) | `tools/android_emulator_smoke.sh` line 30 | `emulator` command fails to start | `avd not found` rc=1 | **KILLED** |
| **M3** | Corrupt host receiver port to reserved 80 | `tools/android_emulator_smoke.sh` line 26 | Host receiver fails to bind | `bind failed` rc=1 | **KILLED** |

---

## 4. Adversarial Edge Cases Considered
1. **Daemon Lock Inheritance:** Without `flock -o`, child `adb` daemon inherits lock descriptor and blocks future packaging/smoke runs. Verified: `flock -o` used, `adb kill-server` executed.
2. **Read-Only Home in Sandbox:** In default sandbox, writing to `$HOME/.android` fails with errno 30 (read-only filesystem). Verified: `$HOME` redirected to `/tmp/android-home`.
3. **Space in Workspace Path:** Repo path contains spaces (`Software Engineering LibreShare`). Verified: script handles space via symlink `/tmp/ls-android-sdk` to avoid emulator path parsing crash.
4. **Stale Download Folder UID:** Prior uninstall can leave `/storage/emulated/0/Android/data/<pkg>` with stale UID, causing subsequent receive to fail. Verified: script explicitly deletes directory before install.
5. **GPU Mode Hang:** Without timeout, headless emulator with failed GPU initialization could hang indefinitely. Verified: 300 s timeout enforced with explicit PID kill.

---

## 5. Resource & Secret Leak Checks
- **No Leaked Daemons:** `ps aux | grep -E 'adb|emulator|qemu'` verified empty after teardown.
- **No Leaked Locks:** `lslocks | grep libreshare` verified empty.
- **No Credentials Logged:** No PINs, private keys, or tokens captured in reports or console logs.

---

## 6. Review Verdict & Deep Review Checklist
- **Verdict: READY**
- **Deep Review Checklist:**
  - Verify physical device testing remains flagged as requiring user hardware in `docs/plans/STATUS.md`.
  - Verify `adb kill-server` was executed and no background daemon remains.
