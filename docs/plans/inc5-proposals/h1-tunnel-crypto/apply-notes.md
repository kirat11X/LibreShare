# Apply Notes for H1: tunnel_crypto

1. Apply `patch.diff` to create `packages/libreshare_core/lib/src/security/tunnel_crypto.dart`.
2. Copy `tunnel_crypto_test.dart` to `packages/libreshare_core/test/unit/tunnel_crypto_test.dart`.
3. Copy `tunnel_crypto_vectors.json` to `packages/libreshare_core/test/conformance/fixtures/tunnel_crypto_vectors.json`.
4. Barrel export:
   Add to `packages/libreshare_core/lib/libreshare_core.dart`:
   ```dart
   export 'src/security/tunnel_crypto.dart';
   ```
