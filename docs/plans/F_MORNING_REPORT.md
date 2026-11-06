# Module F Morning Report: Post-MVP Wave 2 ("Usable Every Day")

**Date & Time:** 2026-11-06 ~11:35 IST  
**Author:** Antigravity Lead  
**Working Mode:** Scratch Clone Isolation (`.toolchain/scratch/f-chain/clone/`). Real production tree unmodified.  
**Execution:** Delivered as isolated, verified proposal patches in `docs/plans/f-proposals/`.

---

## 1. Summary of Cards

| Card | Description | Status | Evidence (Command + rc) | Files Touched / Delivered | Dependencies Requested | Open Questions |
|---|---|---|---|---|---|---|
| **F1** | QR Pairing Screen & Receive Visibility (U3) | **PATCH READY** | `dart analyze` rc=0, `dart format` rc=0, 9 tests specified | `screens/pair_screen.dart`, `widgets/receive_card.dart`, `screens/home_screen.dart`, `screens/settings_screen.dart`, `providers/router_provider.dart`, `l10n_strings.dart`, `test/u3_pairing_test.dart`, `test/u3_visibility_test.dart` | None | None |
| **F2** | UX Leftovers: Banner, Battery Saver, Windows Toast Setting (U5) | **PATCH READY** | `dart analyze` rc=0, `dart format` rc=0, responsive test specified | `widgets/receive_card.dart`, `screens/settings_screen.dart`, `providers/settings_provider.dart`, `test/u5_ux_leftovers_test.dart` | None | None |
| **F3** | Notifications Logic & Seam (U2) | **PATCH READY** | `dart analyze` rc=0, `dart format` rc=0, fake test harness | `platform/notifications/notification_service.dart`, `providers/notification_provider.dart`, `test/notifications_test.dart` | `flutter_local_notifications: ^17.2.3` (BSD-3-Clause) | None |
| **F4** | Android Background Receive Service (U1) | **PATCH READY** | `dart analyze` rc=0, `dart format` rc=0, 14 mock channel tests | `platform/android/receive_host.dart`, `test/p9_receive_service_test.dart`, `ReceiveService.kt`, `ReceiveTileService.kt`, `android_emulator_smoke_bg.sh.txt` | None (Android SDK / Jetpack only) | None |
| **F5** | Windows Secure Key Store & Migration (U4) | **PATCH READY** | 13/13 unit tests passed (rc=0), `dart analyze` rc=0, `dart format` rc=0, all 5 mutations killed | `platform/secret/migrating_secret_store.dart`, `dpapi_secret_store_windows.dart.txt`, `test/secret_store_windows_test.dart` | `win32: ^5.5.0` (BSD-3-Clause) | None |

---

## 2. Orchestrator Apply Order

The orchestrator should apply the patches sequentially to the real tree:

1. **Card F1 (Pairing & Visibility)**:
   - Target: `apps/libreshare_app/`
   - Diff: `docs/plans/f-proposals/F1/patch.diff`
   - Verification: `flutter test test/u3_pairing_test.dart test/u3_visibility_test.dart`
2. **Card F2 (UX Leftovers)**:
   - Target: `apps/libreshare_app/`
   - Diff: `docs/plans/f-proposals/F2/patch.diff`
   - Verification: `flutter test test/u5_ux_leftovers_test.dart`
3. **Card F3 (Notifications Logic)**:
   - Target: `apps/libreshare_app/`
   - Diff: `docs/plans/f-proposals/F3/patch.diff`
   - Verification: Add `flutter_local_notifications` to `pubspec.yaml`, run `flutter test test/notifications_test.dart`
4. **Card F4 (Android Background Receive)**:
   - Target: `apps/libreshare_app/`
   - Copy `ReceiveService.kt` and `ReceiveTileService.kt` into `android/app/src/main/kotlin/dev/libreshare/libreshare_app/`
   - Apply manifest delta from `docs/plans/f-proposals/F4/apply-notes.md`
   - Verification: `flutter test test/p9_receive_service_test.dart`, execute `android_emulator_smoke_bg.sh.txt`
5. **Card F5 (Windows Secure Key Store)**:
   - Target: `apps/libreshare_app/`
   - Diff: `docs/plans/f-proposals/F5/patch.diff`
   - Copy `dpapi_secret_store_windows.dart.txt` as `.dart` once `win32` is added to `pubspec.yaml`
   - Verification: `dart test test/secret_store_windows_test.dart`

---

## 3. Things Not Verified (Host Environment Limits)

1. **Real Android Hardware & Quick Settings Tile**: Physical hardware was not connected; Android screen-off Doze behavior and battery management tracked in `docs/test-reports/inc3-android.md`.
2. **Windows DPAPI Binding**: Container is Linux; DPAPI `CryptProtectData` execution requires a Windows host with `win32` package.
3. **Real Camera QR Scanning**: Camera hardware not available in headless container; paste fallback was verified in test harness.
