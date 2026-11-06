# MVP acceptance run (module B closing measurement)

> **SUPERSEDED 2026-11-06.** The verdict below ("NOT accepted: plaintext app builds") was true at 00:19 and is kept as history. The current result is `docs/test-reports/mvp-acceptance-secure.md` (MVP accepted for Linux + Android with the secure app).

Measured by the orchestrator (Claude) on 2026-11-06 00:13-00:19 IST, each suite run **alone**, one after another, under `/tmp/libreshare-heavy.lock` (`flock -o`), with `dart test -j 1` / `flutter test --concurrency=2`. Packaging and emulator results are from the run of 2026-11-05 23:41 - 2026-11-06 00:13 (same tree; no source changed in between except documentation). Raw logs are in the orchestrator scratchpad (`orch/b4/`, `orch/b3b/`).

## Verdict

**The MVP is NOT accepted yet.** Everything below is green, **but the app builds are plaintext**: `apps/libreshare_app/lib/providers/engine_provider.dart` creates the engine without `security:`, so the Linux/Android app does not use TLS, the verification code, PIN or pinned keys, and the Settings PIN "Save" does not store the PIN. The command-line tool `ls` IS encrypted by default. The blocker is card **D1** in `docs/plans/HANDOFF.md` (module D). Until `APP_SECURE_WIRED: YES` do not call any app build "encrypted" and do not run the "both screens show the same 6-digit code" demo step.

## Results (every command and its exit code)

| # | Check | Command | rc | Result |
|---|---|---|---|---|
| 1 | Static analysis | `dart analyze --fatal-infos` (repo root) | 0 | No issues found |
| 2 | Formatting | `dart format --output=none --set-exit-if-changed .` | 0 | clean |
| 3 | Core has no Flutter | `grep -RnE "package:flutter\|dart:ui" packages/libreshare_core/lib` | 1 | no matches (1 = none found) |
| 4 | Core tests | `cd packages/libreshare_core && dart test -j 1` | 0 | **+2583 ~1**, all passed (2:53) |
| 5 | CLI tests | `cd packages/libreshare_cli && dart test -j 1` | 0 | **+75**, all passed (1:03) |
| 6 | Loopback transfer, 100 MiB | `tools/loopback_smoke.sh 100 53879` | 0 | byte-identical, 19.0 MiB/s, COMPLETED (plaintext flag on both ends) |
| 7 | App tests | `cd apps/libreshare_app && flutter test --concurrency=2` | 0 | **+405**, all passed (0:53); includes the 4 new Open Contacts tests |
| 8 | Packaging | `tools/package_prototype.sh linux android` | 0 | Linux tarball + 4 Android APKs, built 00:09-00:11 |
| 9 | Checksums | `cd dist/prototype && sha256sum -c SHA256SUMS` | 0 | 5 of 5 OK |
| 10 | Emulator smoke | `tools/android_emulator_smoke.sh` (AVD `ls_test`, android-35 x86_64, KVM) | 0 | **SMOKE PASSED (18 checks)**: Android->Linux and Linux->Android, byte-identical, no `.lspart` leftovers, no crash in logcat |

Artifacts (`dist/prototype/`, SHA-256):

```
0576a0d876ed7318a7103c8b0bf38e5c482fe051f98f642fb932ec6bf4c80c67  libreshare-1.0.0-linux-x64.tar.gz
aea97861c7081bb67e739ece0f34e8dc8b043fe409f41d808783adb4f718825c  libreshare-1.0.0-android-arm64-v8a.apk
07f194db0a9fc13ff9f71dd298680a2855989628a6cf1d74f4b44a704e490f34  libreshare-1.0.0-android-armeabi-v7a.apk
18c76dd5ea19a8e7aa828fa51970ea0236e8b9e871869057102a3f46a200ff32  libreshare-1.0.0-android-universal.apk
8e077700a955982371d010c77774147d5c5e2260707b40b0df2a3a85a9a6c41f  libreshare-1.0.0-android-x86_64.apk
```

These artifacts are newer than the last app source edit (Open Contacts, 23:24:40) so they contain it. They are **plaintext app builds** (see Verdict).

## Against the MVP cut (`docs/plans/mvp.md`, "IN" table)

| Part | State |
|---|---|
| Increments 1-2 (protocol, transfer, discovery, apps) | DONE; emulator smoke 18/18 |
| Increment 3 core (TLS 1.3 + pinning, signed proof, SAS, consent, PIN, key-change refusal, rate limits, signed goodbye, Contacts-only gate) | DONE and green in core (2583 tests) and CLI (75); the P6a engine/CLI wiring gate is measured green; the **adversarial review (card C5/D3) is still outstanding**, so `P6A_GATE` stays `API-READY` |
| MVP-App screens (SAS digits, key-changed warning, PIN setting, fingerprint, contacts) | screens exist and pass **fake-engine** tests only; **not wired to the secure engine** (card D1) |
| MVP-Android fixes (F3: default folder, Open/Show in folder, real device name, honest failure texts) | DONE; verified on the emulator in both directions |
| Packaging | Linux + Android built and checksummed (plaintext app); **Windows not built** (code never compiled; see below) |
| Demo guide + known limits | written (`docs/dev/demo-mvp.md`), with `[PENDING: D1 secure wiring]` on the steps that need the secure app |

Demo script status: step 1 (install) works; step 2 (same 6-digit code on both screens) **cannot be shown until D1**; step 3 (no code the second time) likewise; step 4 (wrong PIN / changed key / stranger) works with the CLI only; step 5 (Windows) needs a Windows build.

## Adjustments made to tests and scripts during this run (all disclosed)

- Smoke and e2e scripts, and some CLI tests, got `--insecure-plaintext` on their **setup lines only** (no assertion changed), because the CLI now defaults to TLS and the app is still plaintext. `tools/android_emulator_smoke.sh` got the flag on its two CLI calls and one new step that taps **Keep default** on the one-time "Where should received files go?" dialog (F3 UX); all its assertions are unchanged. After D1 the flag should be removed again (card D5).
- With the user's approval (2026-11-05, "yes") the app shows decimal units (KB/MB, 1000-based); 8 expected strings in 3 old tests were updated by the orchestrator accordingly.
- No acceptance test was edited to make it pass.

## Findings of this run

1. **Lock leak:** `flock /tmp/libreshare-heavy.lock tools/android_emulator_smoke.sh` leaves the `adb` server holding the lock after the script exits; the next locked command waited 27 minutes. Fix: `flock -o` (tested) and `adb kill-server` afterwards. Documented in `docs/plans/HANDOFF.md` section 3.
2. **Memory:** a Gradle daemon left over from a package build held 4.3 GB and delayed the emulator step; run `gradle --stop` after Android builds.
3. The earlier reds reported by the Lead (core -18, "2 files red") came from overlapping test runs (fixed ports 53318.. and memory pressure); serialized runs show none.

## Known limits (not fixed in the MVP)

- No cap on simultaneous connections on the server; forged signed-goodbyes spend the verify budget.
- Contacts-only greeting is one-shot: no retry and no UDP fallback.
- NFR-02 speed (hashing / throughput target) deferred; loopback 19.0 MiB/s is the measured number.
- Windows: code never compiled or run; known risks are `FileMode.append` + `setPosition` (R13), `parentDir("C:\\dir")` returning `"C:"`, and an unverified `File.rename` assumption. Needs a Windows PC or a GitHub Actions run (not done; nothing is pushed).
- Android FileProvider root-wide scope accepted for the MVP; hardening queued as card D4.
- Android background receive (P9), notifications, QR pairing screen, Contacts-only toggle UI: deferred by decision.

## What closes the MVP

Module D (`docs/plans/MODULE_D_PROMPT.md`): D1 secure wiring + real PIN -> C5 adversarial review -> D4 -> D5 repackage and manual emulator check -> orchestrator re-runs this table and flips `APP_SECURE_WIRED`, `P6A_GATE: DONE`, `MVP_APP_DONE`, `PACKAGING_DONE`.
