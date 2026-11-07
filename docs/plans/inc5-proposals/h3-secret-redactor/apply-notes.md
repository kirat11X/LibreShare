# Apply Notes for H3: secret_redactor

1. Apply `patch.diff` to create `packages/libreshare_core/lib/src/security/secret_redactor.dart`.
2. Copy `secret_redactor_test.dart` to `packages/libreshare_core/test/unit/secret_redactor_test.dart`.
3. Barrel export:
   Add to `packages/libreshare_core/lib/libreshare_core.dart`:
   ```dart
   export 'src/security/secret_redactor.dart';
   ```
