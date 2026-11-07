# Apply Notes for H2: share_link

1. Apply `patch.diff` to create `packages/libreshare_core/lib/src/share/share_link.dart`.
2. Copy `share_link_test.dart` to `packages/libreshare_core/test/unit/share_link_test.dart`.
3. Barrel export:
   Add to `packages/libreshare_core/lib/libreshare_core.dart`:
   ```dart
   export 'src/share/share_link.dart';
   ```
