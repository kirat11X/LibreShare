# MVP acceptance run, secure app (closing measurement)

Measured by the orchestrator (Claude) on 2026-11-06, 09:01-09:45 by `date`. Every suite ran **alone**, one after another, under `/tmp/libreshare-heavy.lock` (`flock -o`), with `dart test -j 1` / `flutter test --concurrency=1|2`, a silence watchdog that kills only the process group it started, and `adb kill-server` / `gradle --stop` afterwards. The exit codes below are real (`$?`), not read from an agent's report.

This report **supersedes** `docs/test-reports/mvp-acceptance.md`, whose verdict ("NOT accepted: the app builds are plaintext") was true when it was written (2026-11-06 00:19). That file is kept as the history.

## Verdict

**The MVP is accepted for Linux and Android**, with the limits listed at the end. The app now builds the engine with the secure profile (TLS 1.3 with a pinned certificate, signed client proof, 6-digit verification code, PIN guard, Contacts-only gate). The Linux tarball and the four Android APKs in `dist/prototype/` were rebuilt from that code (09:22-09:25), their checksums verify, and on an Android emulator the **same 6-digit code appeared on both screens** in both directions.

STATUS flags set from this evidence: `APP_SECURE_WIRED: YES` (09:20:58), `P6A_GATE: DONE` (07:41:18), `PACKAGING_DONE: YES` (09:37:25), `MVP_APP_DONE: YES`.

**Not part of this acceptance:** a Windows build (never compiled), a real phone, launching the Linux desktop app in this container (no display). See "Known limits".

## Results (every command and its exit code)

| # | Check | Command | rc | Result | Measured |
|---|---|---|---|---|---|
| 1 | Static analysis | `dart analyze --fatal-infos` (repo root) | 0 | No issues found | 09:37:55 |
| 2 | Formatting | `dart format --output=none --set-exit-if-changed .` | 0 | 280 files, 0 changed | 09:38:00 |
| 3 | Core has no Flutter | `grep -RnE "package:flutter\|dart:ui" packages/libreshare_core/lib` | 1 | no matches (1 = none found, as required) | 09:38:00 |
| 4 | Core tests | `cd packages/libreshare_core && dart test -j 1` | 0 | **+2591 ~1**, all passed (3:03). The one skip is the opt-in `LS_SLOW=1` test | 09:41:10 |
| 5 | CLI tests | `cd packages/libreshare_cli && dart test -j 1` | 0 | **+75**, all passed (1:04) | 09:42:20 |
| 6 | Loopback transfer, 100 MiB | `tools/loopback_smoke.sh 100 53879` | 0 | byte-identical, 17.9 MiB/s (plaintext flags on both ends, as before; see limits) | 09:42:30 |
| 7 | App tests, twice | `cd apps/libreshare_app && flutter test --no-pub --concurrency=2 --timeout 60s` | 0 / 0 | **+478** both times, all passed (2:02 each) | 09:16:57 and 09:20:37 |
| 7a | D1 files, 3 runs | the 14 `test/d1*_test.dart` files, `--concurrency=1`, three times | 0 / 0 / 0 | **+73** each time | 09:11-09:15 |
| 8 | P6a files, 3 runs | 12 core files (the P6a set, including the new `c5_survivors_test.dart`) plus `cli_security_test.dart`, each file alone, three times (39 runs) | 0 x 39 | all green | 07:34-07:41 |
| 9 | Debug APK | `flutter build apk --debug` (apps/libreshare_app) | 0 | built (09:00:16); no `lib` file changed afterwards | 09:00 |
| 10 | Packaging | `tools/package_prototype.sh linux android` | 0 | Linux tarball 09:22:59, Android APKs 09:25:02-09:25:49 | 09:25:51 |
| 11 | Checksums | `cd dist/prototype && sha256sum -c SHA256SUMS` | 0 | 5 of 5 OK | 09:25:52 |
| 12 | Secure emulator smoke | `tools/android_emulator_smoke.sh` (AVD `ls_test`, android-35 x86_64, KVM, headless) | 0 | **SMOKE PASSED (26 checks, 0 FAIL)** | 09:34:35-09:36:46 |

Tests 7 and 7a ran on the real tree after the user's go-ahead (08:47) and the guarded apply (`.toolchain/scratch/d1-apply/apply.sh`, snapshots in `.toolchain/snap/d1-apply*`). No file under `lib/` of the three packages changed after the packaged build (checked with `find -newermt '2026-11-06 09:22:00'`: 0 files), so the artifacts correspond to the tested source.

### Artifacts (`dist/prototype/`, SHA-256)

```
a5270e9d9d6234660927a5c3d52df9d82593cc585f3915526f3847bd2e50b318  libreshare-1.0.0-linux-x64.tar.gz
ee7b21bed5055a66501b53e2b7c5e609a35cfb172c77a4d8f141c74a1605f62a  libreshare-1.0.0-android-arm64-v8a.apk
053369c1306a8ece9c5f864c3eeabc2e533ccebb0ad9e9ea7d76c9de98158c0c  libreshare-1.0.0-android-armeabi-v7a.apk
9618476fa2237cf16f343a452b7f3c954f60c9e4b61a2fd92a17234c578e3a60  libreshare-1.0.0-android-universal.apk
cc1bf00b87771df95c48b0a5787be8ab10dc110449396735b1a2a7b7bb45b8f5  libreshare-1.0.0-android-x86_64.apk
```

The earlier plaintext artifacts are kept (not deleted) in `.toolchain/snap/d5/dist-plaintext-20261106-090926`.

## The emulator smoke, check by check (26 PASS lines)

Setup: a **secure** host CLI receiver (`--identity-dir`, no `--insecure-plaintext`, no `--insecure-tofu`) and a secure host CLI sender. The script reads the code the CLI prints and compares it with what the app shows, then answers the CLI's "Do the codes match?" question on stdin.

| Group | Checks |
|---|---|
| Setup | host receiver is listening; emulator boots (19 s); `adb install` of the x86_64 APK; the app shows Home (Nearby) |
| A: Android sends to Linux | Add-device lookup finds the host (confirm dialog); device card appears on Home; Send screen lists 2 selected files; **host CLI printed a 6-digit code; the app (sender screen) shows the SAME code**; app reports completion; host printed COMPLETED; files byte-identical (1 KiB + 20 MiB); no `.lspart` leftovers |
| B: Linux sends to Android | Receive turned on; the app listens on 53318 inside the emulator; the Incoming transfer dialog appears; the dialog marks the sender as **New device**; **host CLI printed a 6-digit code; the app (receiver dialog) shows the SAME code**; sender CLI reports COMPLETED; the app shows "Received 2 files"; pulled files byte-identical |
| S7: key storage | the app's `security` directory exists and is mode 700; a `*.secret` identity key file exists; every file in it is mode 600 (read with `adb root`; the release APK is not debuggable, so `run-as` does not work) |
| Health | no app crash in `logcat -b crash` |

The PASS lines contain no digits of the code, no keys and no PINs. Screenshots of the two code screens: `docs/test-reports/img/d5-secure-sender-code.png` (sender) and `docs/test-reports/img/d5-secure-incoming-dialog.png` (receiver). The code shown there belonged to a throwaway session on an emulator with throwaway keys.

### Checked by hand on the emulator (not in the script)

- **Settings -> PIN -> Fixed -> 6-digit PIN -> Save** shows "PIN configured". The first attempt left the app (the Back key closed the keyboard and the screen), so it was redone with the keyboard kept open and Save pressed at the located bounds; the second attempt succeeded.
- **Settings -> Your fingerprint** shows 16 hex digits in groups of four with a "Copy fingerprint" button (the format is also asserted by the regexp in `settings_screen_test.dart:50`).

## Findings of this run

1. **Fixed before the gate:** the app test `listeningPorts` helper scanned machine-wide `/proc/net/tcp`, which is unsafe under `--concurrency=2` (127.0.0.2 is every app test's bind address). It now filters by socket inode from `/proc/self/fd`, with a positive and a negative twin test (`d1b_listening_ports_helper_test.dart`). Re-gated twice: +478, rc 0.
2. **Fixed before D5:** the smoke script's old draft ignored that the secure CLI asks "Do the codes match?" on stdin (EOF counts as "no"). It now uses fifos and compares the printed code with the on-screen code.
3. **Process note:** the Lead's own C5 report was not used as evidence; `P6A_GATE: DONE` rests on the independent re-verification (agent `a5fae00527fd43c37`, report `.toolchain/scratch/c5-reverify/c5-reverify-report.md`) and the 39 alone-runs in row 8. It added `packages/libreshare_core/test/security/c5_survivors_test.dart` (the engine defaults `allowInsecurePeers` to false, and refuses a TLS 1.2-only `openssl s_server` with `InsecurePeerException`; skipped when `openssl` is absent).
4. Open items from the C5 re-verification (missing `security/mitm_test.dart`, dead code at `libreshare_engine.dart:921`, a redundant compare in `file_sender.dart`, weak p6a tests and silent skips, openssl-dependent TLS-floor tests) are recorded in `docs/plans/INC3_CLOSURE_PLAN.md`; none blocks the MVP.

## Known limits (not fixed in the MVP)

- **Windows:** code never compiled or run; known risks are `FileMode.append` + `setPosition` (R13), `parentDir("C:\\dir")` returning `"C:"`, and an unverified `File.rename` assumption. Needs a Windows PC or a GitHub Actions run (nothing is pushed). First item of Wave 1; waits for the user's answer on the build route.
- **No real phone:** Android was tested on an x86_64 emulator only (NAT between emulator and host, so the 20 MiB time of ~10 s is not representative).
- **Linux desktop app:** built and packaged (tarball checksum OK) but not launched here (no display in the container); its logic is covered by the 478 app tests.
- **Speed (NFR-02):** the 100 MiB loopback ran at 17.9 MiB/s on the plaintext flags against a target of 300 MB/s. The secure path was not profiled; that is Increment 4 (card I4.1, profile first).
- **PIN-guard counters** are in memory only: they reset when the receiver restarts (decision with the user still open).
- Server connection cap, forged signed-goodbyes spending the verify budget, one-shot Contacts-only greeting: unchanged from `mvp-acceptance.md`.
- Android FileProvider root-wide scope accepted for the MVP (card D4 queued). Android background receive, notifications, QR pairing screen, Contacts-only toggle UI: deferred by decision (Module F, held).
- A key-changed peer is refused with a warning and no Accept button: covered by automated tests (core, CLI exit code 80, app widget tests), not shown on a device.

## What happens next

Nothing in `docs/plans/post-mvp-plan.md` starts until the orchestrator flips `POSTMVP_W1_READY: YES`, which needs the user's answer on the Windows build route (decision D1 there). Module F (Wave 2, patch-only) stays held for the same reason.
