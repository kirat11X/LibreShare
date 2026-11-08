# Card T2: CLI End-to-End Matrix Integration Suite Report

- Test file: packages/libreshare_cli/test/cli_matrix_e2e_test.dart
- Mode: End-to-end compiled CLI kernel binary execution against real sockets and temporary storage

## Gate Measurements
- Run 1: 6/6 passed (7.2s, rc=0)
- Run 2: 6/6 passed (7.1s, rc=0)
- Run 3: 6/6 passed (7.0s, rc=0)
- Overall Exit Code: rc=0

## Mutation Verification (3/3 killed)
- M1: matrix 5 wrong-PIN expected exit changed from 82 to 0 -> KILLED (Actual: <82>, rc=1)
- M2: matrix 4 reserved filename expected as CON.txt instead of _CON.txt -> KILLED (Actual: false, rc=1)
- M3: matrix 6 unattended decline expected sender exit 0 -> KILLED (Actual: <1>, rc=1)
- Clean Restoration: 6/6 passed (7.1s, rc=0)

## Code Quality
- `dart analyze packages/libreshare_cli/test/cli_matrix_e2e_test.dart`: 0 errors, 0 warnings (rc=0)
- `dart format --output=none --set-exit-if-changed`: 0 formatting diffs (rc=0)
