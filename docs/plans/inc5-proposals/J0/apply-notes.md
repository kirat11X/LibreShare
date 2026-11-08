# Apply Notes for Card J0: Wave 0 Contracts

The orchestrator should apply the following files when declaring `INC5_WAVE0: APPLIED`:
1. Move `tunnel_provider.dart` to `packages/libreshare_core/lib/src/tunnel/tunnel_provider.dart`.
2. Move `origin_candidate.dart` to `packages/libreshare_core/lib/src/model/origin_candidate.dart`.
3. Move `share_models.dart` to `packages/libreshare_core/lib/src/model/share_models.dart`.
4. Update `docs/protocol/LSP-1.md` Section 4.5 using `lsp1-section-4.5.md`.
5. Update `docs/protocol/schemas/tunnel-offer.schema.json`.
6. Add barrel exports to `packages/libreshare_core/lib/libreshare_core.dart`:
   ```dart
   export 'src/tunnel/tunnel_provider.dart';
   export 'src/model/origin_candidate.dart';
   export 'src/model/share_models.dart';
   ```
