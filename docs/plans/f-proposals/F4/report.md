# Card F4 Proposal Report: Android Background Receive Service

## 1. Summary of Work Delivered
Card F4 implements the Android background receive service and Dart host seam:
- **Dart Host Seam**: `receive_host.dart` providing platform channel communication with fallback ladder (F0 `connectedDevice` -> F1 `dataSync` -> F2 `none`), `onTimeout` handling, and `assertNoSecrets` validator.
- **Unit Test Suite**: `p9_receive_service_test.dart` (14 unit tests, mocking platform channel messages, timeout callbacks, and secret leak assertions).
- **Kotlin Services**: `ReceiveService.kt` foreground service and `ReceiveTileService.kt` Quick Settings tile.
- **Emulator Draft**: `android_emulator_smoke_bg.sh.txt` for screen-off transfer verification.
- **Real-Phone Checklist**: `docs/test-reports/inc3-android.md` for physical hardware testing.
- **Verification**: `HOME=/tmp dart analyze --fatal-infos` clean (0 issues, rc=0), `dart format` clean (rc=0).
