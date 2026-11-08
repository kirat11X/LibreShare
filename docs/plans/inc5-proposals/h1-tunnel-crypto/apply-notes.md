# Apply Notes for H1: tunnel_crypto

1. Apply `patch.diff` to create `packages/libreshare_core/lib/src/security/tunnel_crypto.dart`.
2. Copy `tunnel_crypto_test.dart` to `packages/libreshare_core/test/unit/tunnel_crypto_test.dart`.
   (Note: Known-answer vectors are self-contained in `tunnel_crypto_test.dart`. Do NOT copy any file into `test/conformance/fixtures/`, which is reserved exclusively for schema DTO golden fixtures).
3. Barrel export:
   Add to `packages/libreshare_core/lib/libreshare_core.dart`:
   ```dart
   export 'src/security/tunnel_crypto.dart';
   ```
