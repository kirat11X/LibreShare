# Increment 4 — Card A3 / P4-4 Apply Notes

## Applying the Patch

From repository root:
```bash
patch -p0 < docs/plans/inc4-proposals/P4-4/patch.diff
cp docs/plans/inc4-proposals/P4-4/hashing_provider_test.dart packages/libreshare_core/test/unit/hashing_provider_test.dart
```

## Gate Verification

```bash
source tools/env.sh
export HOME="$PWD/.toolchain/tmp"
export TMPDIR="$PWD/.toolchain/tmp"

# 1. Format
dart format --output=none --set-exit-if-changed packages/libreshare_core/lib/

# 2. Analyze
dart analyze packages/libreshare_core/lib/

# 3. Unit tests
cd packages/libreshare_core
dart test test/unit/hashing_test.dart test/unit/hashing_provider_test.dart test/unit/file_sender_test.dart test/unit/file_receiver_test.dart test/integration/large_transfer_test.dart
```
