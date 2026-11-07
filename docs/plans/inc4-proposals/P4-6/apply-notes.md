# Increment 4 — Card C1 / P4-6 Apply Notes

## Applying the Proposal

From repository root:
```bash
cp docs/plans/inc4-proposals/P4-6/candidate.dart packages/libreshare_core/lib/src/connection/candidate.dart
cp docs/plans/inc4-proposals/P4-6/connection.dart packages/libreshare_core/lib/src/connection/connection.dart
cp docs/plans/inc4-proposals/P4-6/connection_manager.dart packages/libreshare_core/lib/src/connection/connection_manager.dart
cp docs/plans/inc4-proposals/P4-6/http_connection.dart packages/libreshare_core/lib/src/connection/http_connection.dart
cp docs/plans/inc4-proposals/P4-6/candidate_test.dart packages/libreshare_core/test/unit/candidate_test.dart
cp docs/plans/inc4-proposals/P4-6/connection_manager_test.dart packages/libreshare_core/test/unit/connection_manager_test.dart
```

## Quality Gate Verification

```bash
source tools/env.sh
dart format --output=none --set-exit-if-changed packages/libreshare_core/lib/src/connection/
dart analyze packages/libreshare_core/lib/src/connection/
cd packages/libreshare_core
dart test test/unit/candidate_test.dart test/unit/connection_manager_test.dart
```
