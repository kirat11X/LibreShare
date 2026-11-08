# Apply Notes for Card J5: CloudflaredProvider, BinaryInstaller, ProcessSupervisor, ManualUrlProvider, ZrokProvider

## 1. Apply Patch
Apply `patch.diff` with `patch -p0 < docs/plans/inc5-proposals/J5/patch.diff` from the repo root to create:
- `packages/libreshare_core/lib/src/tunnel/binary_installer.dart`
- `packages/libreshare_core/lib/src/tunnel/cloudflared_provider.dart`
- `packages/libreshare_core/lib/src/tunnel/cloudflared_versions.dart`
- `packages/libreshare_core/lib/src/tunnel/manual_url_provider.dart`
- `packages/libreshare_core/lib/src/tunnel/process_supervisor.dart`
- `packages/libreshare_core/lib/src/tunnel/zrok_provider.dart`

## 2. Copy Test Files
```bash
cp docs/plans/inc5-proposals/J5/test/unit/binary_installer_test.dart packages/libreshare_core/test/unit/
cp docs/plans/inc5-proposals/J5/test/unit/process_supervisor_test.dart packages/libreshare_core/test/unit/
```

## 3. Barrel Exports
Add to `packages/libreshare_core/lib/libreshare_core.dart`:
```dart
export 'src/tunnel/binary_installer.dart';
export 'src/tunnel/cloudflared_provider.dart';
export 'src/tunnel/cloudflared_versions.dart';
export 'src/tunnel/manual_url_provider.dart';
export 'src/tunnel/process_supervisor.dart';
export 'src/tunnel/zrok_provider.dart';
```
