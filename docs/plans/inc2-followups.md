# Inc 2 follow-ups found by the Android emulator run (orchestrator-owned, 2026-11-05)

Source: `docs/test-reports/android-emulator.md` (agent AE, defects numbered as in that report). Each defect is routed to the package that already touches the file, so nothing is fixed twice and no two agents edit one file.

| # | Sev | Defect | Routed to | Test that must exist (written first by the package's tester) |
|---|---|---|---|---|
| 1 | High | Backgrounding / screen-off blocks the app's network after ~5 s; sender shows a misleading "Could not reach" | **P9** (Android foreground service). Interim: `FLAG_KEEP_SCREEN_ON` in `MainActivity.kt` (done by AE). Message wording: **F3** | P9: service-host tests; F3: failure text distinguishes "peer unreachable at start" from "connection lost mid-transfer" |
| 2 | High | Receiving while backgrounded wedges: Accept sticks at 0%, next send hangs until force-stop | **F3 investigation first** (emulator, reproduce), fix in the owner of the file it turns out to be; likely overlaps P9 | a regression test at the lowest layer that can show it (engine or app) |
| 3 | High | Received files hidden in `Android/data`; Open/Show in folder do nothing on Android | **F3** (app + `android/**`): public default folder or MediaStore + `ACTION_VIEW`/FileProvider through a Kotlin channel | app tests with fakes for the channel; emulator re-run of the smoke script |
| 4 | Med-high | Manually added (IP/link/QR) peers vanish after 90 s | **P6b** (`peer_registry.dart`), tests in `unit/peer_registry_remove_test.dart` | plaintext + secure |
| 5 | Med | Android names itself `localhost` | **F3** (`device_identity.dart` + Kotlin channel; fall back to "Android phone") | app test with fake channel |
| 6 | Med | Unwritable download dir surfaces late as PROTOCOL_ERROR | **P4** (`file_receiver.dart`): 507 INSUFFICIENT_STORAGE at createSession, both profiles (LSP-1 4.3.4 step 11 updated 2026-11-05) | `unit/receiver_secure_dir_test.dart` |
| 7 | Med | No receiver idle timeout, dead sessions reserve names | **Inc 4** (LSP-1 section on timeouts: chunk idle timeout 30 s LAN / 60 s tunnel is [I4]); P4 only tests `sessionTtl` | Inc 4 plan must include it |
| 8 | Low | universal APK versionCode 1 vs split 4001 (downgrade on flavour switch) | documented in `docs/dev/testing-prototype.md`; fix in `tools/package_prototype.sh` only if trivial | - |
| 9-11 | Low | address flips, FAB overlaps "Add by IP", "120 MB" label for MiB | **F3** (cosmetic) | widget tests |
| 12 | Info | POST_NOTIFICATIONS declared but never requested | **P8/P9** | - |
| 13 | Info | `reusePort not supported` log line | ignore (benign) | - |

F3 (Inc 2 app follow-ups) runs after P3-P6b testers finish, to stay inside the usage budget: tester (high) writes app-level tests first, coder (medium) implements, AE's `tools/android_emulator_smoke.sh` is the end-to-end check.
