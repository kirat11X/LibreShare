# Card W7 Apply Notes

## Affected Files
Production files:
- `packages/libreshare_core/lib/src/rendezvous/ntfy_backend.dart` (new)

Test files:
- `packages/libreshare_core/test/unit/rendezvous/ntfy_backend_test.dart` (new)
- `packages/libreshare_core/test/unit/rendezvous/fake_ntfy_server.dart` (new)

## Patch Application Instructions
1. Apply patch to root workspace:
   ```bash
   patch -p0 < docs/plans/inc6-proposals/W7/patch.diff
   ```
2. Copy test files:
   ```bash
   mkdir -p packages/libreshare_core/test/unit/rendezvous
   cp docs/plans/inc6-proposals/W7/test/ntfy_backend_test.dart packages/libreshare_core/test/unit/rendezvous/
   cp docs/plans/inc6-proposals/W7/test/fake_ntfy_server.dart packages/libreshare_core/test/unit/rendezvous/
   ```
3. Run verification:
   ```bash
   dart test packages/libreshare_core/test/unit/rendezvous/ntfy_backend_test.dart
   ```
