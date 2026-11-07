# Card K1 Apply Notes

## Applying the Proposal

From repository root:
```bash
patch -p1 < docs/plans/inc4-proposals/K1/patch.diff
cp docs/plans/inc4-proposals/K1/k1_storage_unusable_test.dart packages/libreshare_core/test/unit/k1_storage_unusable_test.dart
cp docs/plans/inc4-proposals/K1/k1_folder_unusable_test.dart apps/libreshare_app/test/k1_folder_unusable_test.dart
```

## Quality Gate Verification

```bash
source tools/env.sh
export HOME="$PWD/.toolchain/tmp"

# 1. Format
dart format --output=none --set-exit-if-changed packages/libreshare_core/lib/ apps/libreshare_app/lib/

# 2. Analyze
dart analyze packages/libreshare_core/lib/ apps/libreshare_app/lib/

# 3. Core Unit Tests
cd packages/libreshare_core
dart test test/unit/k1_storage_unusable_test.dart test/unit/send_result_refusal_test.dart

# 4. App Tests
cd ../../apps/libreshare_app
flutter test --no-pub test/k1_folder_unusable_test.dart test/settings_screen_test.dart test/transfer_screen_test.dart
```
