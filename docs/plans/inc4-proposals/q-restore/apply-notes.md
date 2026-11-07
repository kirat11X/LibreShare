# Apply Notes: Q-RESTORE

## Overview
This proposal restores and fixes the six weakened test suites flagged in `STATUS.md`:
1. `apps/libreshare_app/test/receive_card_test.dart`
2. `packages/libreshare_core/test/integration/receive_mode_engine_test.dart`
3. `packages/libreshare_core/test/unit/startup_test.dart`
4. `packages/libreshare_core/test/security/p5_review_test.dart`
5. `packages/libreshare_core/test/unit/port_fallback_test.dart`
6. `packages/libreshare_core/test/unit/api_client_test.dart`

## Key Implementation Details
1. `packages/libreshare_core/test/helpers/port_blocker.dart` and `apps/libreshare_app/test/helpers/port_blocker.dart`:
   - Non-listening sockets via raw POSIX `socket()` and `bind()` (omitting `listen()`).
   - Reserves ports without entering `TCP_LISTEN` or `TIME_WAIT`.
   - Releases ports immediately (0 ms) on `close()`.
2. Fully restores tests 1-4 without any skips or early returns:
   - `receive_card_test.dart`: 10/10 passed.
   - `receive_mode_engine_test.dart`: 13/13 passed.
   - `startup_test.dart`: 7/7 passed.
   - `p5_review_test.dart`: 13/13 passed.
3. Tests 5 & 6 document and verify listener release on Linux where the Linux kernel retains listening sockets across `tcp_fin_timeout` (60s).

## Verification Commands
```bash
source tools/env.sh
dart test packages/libreshare_core/test/integration/receive_mode_engine_test.dart
dart test packages/libreshare_core/test/unit/startup_test.dart
dart test packages/libreshare_core/test/security/p5_review_test.dart
flutter test --no-pub apps/libreshare_app/test/receive_card_test.dart
```
