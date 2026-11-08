# Apply Notes for Card J4: OriginPullConnection & TunnelConnection

## 1. Apply Patch
Apply `patch.diff` with `patch -p0 < docs/plans/inc5-proposals/J4/patch.diff` from the repo root to create:
- `packages/libreshare_core/lib/src/connection/origin_pull_connection.dart`
- `packages/libreshare_core/lib/src/connection/tunnel_connection.dart`

## 2. Copy Test Files
```bash
cp docs/plans/inc5-proposals/J4/origin_pull_connection_test.dart packages/libreshare_core/test/unit/
cp docs/plans/inc5-proposals/J4/tunnel_fallback_test.dart packages/libreshare_core/test/integration/
cp docs/plans/inc5-proposals/J4/link_resume_test.dart packages/libreshare_core/test/integration/
```

## 3. Barrel Exports
Add to `packages/libreshare_core/lib/libreshare_core.dart`:
```dart
export 'src/connection/origin_pull_connection.dart';
export 'src/connection/tunnel_connection.dart';
```
