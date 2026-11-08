# Apply Notes for Card Wave 1b (Cards J1 & J2)

## 1. Apply Patch
Apply `patch.diff` with `patch -p0 < docs/plans/inc5-proposals/wave1b/patch.diff` from the repo root to create:
- `packages/libreshare_core/lib/src/tunnel/fake_tunnel_provider.dart`
- `packages/libreshare_core/lib/src/server/tunnel_origin_server.dart`

## 2. Copy Test Files
Copy the 5 verified test suites:
```bash
cp docs/plans/inc5-proposals/wave1b/fake_tunnel_provider_test.dart packages/libreshare_core/test/unit/
cp docs/plans/inc5-proposals/wave1b/origin_limits_test.dart packages/libreshare_core/test/security/
cp docs/plans/inc5-proposals/wave1b/token_lifecycle_test.dart packages/libreshare_core/test/integration/
cp docs/plans/inc5-proposals/wave1b/hostile_provider_test.dart packages/libreshare_core/test/security/
cp docs/plans/inc5-proposals/wave1b/e2e_ciphertext_test.dart packages/libreshare_core/test/security/
```

## 3. Barrel Exports
Add to `packages/libreshare_core/lib/libreshare_core.dart`:
```dart
export 'src/tunnel/fake_tunnel_provider.dart';
export 'src/server/tunnel_origin_server.dart';
```
