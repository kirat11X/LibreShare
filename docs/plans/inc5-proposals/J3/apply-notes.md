# Apply Notes for Card J3: LinkShare & ShareStore

## 1. Apply Patch
Apply `patch.diff` with `patch -p0 < docs/plans/inc5-proposals/J3/patch.diff` from the repo root to create:
- `packages/libreshare_core/lib/src/share/link_share.dart`
- `packages/libreshare_core/lib/src/share/share_store.dart`

## 2. Copy Test Files
```bash
cp docs/plans/inc5-proposals/J3/link_share_test.dart packages/libreshare_core/test/unit/
cp docs/plans/inc5-proposals/J3/share_store_test.dart packages/libreshare_core/test/unit/
```

## 3. Barrel Exports
Add to `packages/libreshare_core/lib/libreshare_core.dart`:
```dart
export 'src/share/link_share.dart';
export 'src/share/share_store.dart';
```
