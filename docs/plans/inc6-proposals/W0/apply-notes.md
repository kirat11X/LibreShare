# Card W0 Apply Notes

## Summary
Introduces Increment 6 Wave 0 specifications (`docs/protocol/rendezvous/LSP-R1.md`), JSON schemas (`rendezvous-envelope.schema.json`, `rendezvous-record.schema.json` under `docs/protocol/rendezvous/schemas/`), ADR 0003 (no hole punching), `inc6-seams.md`, one-line pointer in `docs/protocol/LSP-1.md`, and core contracts/interfaces in `packages/libreshare_core/lib/src/rendezvous/`. Rendezvous schemas live outside `docs/protocol/schemas/` to preserve existing LSP-1.0 and LSP-1.1 conformance tests, include complete `examples` vectors, and carry their own dedicated conformance test `test/conformance/rendezvous_schema_test.dart`.

## Files Touched / Created
- `docs/adr/0003-no-hole-punching-in-ladder.md`
- `docs/protocol/LSP-1.md`
- `docs/protocol/rendezvous/LSP-R1.md`
- `docs/protocol/rendezvous/schemas/rendezvous-envelope.schema.json`
- `docs/protocol/rendezvous/schemas/rendezvous-record.schema.json`
- `docs/plans/inc6-seams.md`
- `packages/libreshare_core/lib/libreshare_core.dart`
- `packages/libreshare_core/lib/src/rendezvous/records.dart`
- `packages/libreshare_core/lib/src/rendezvous/rendezvous_backend.dart`
- `packages/libreshare_core/lib/src/rendezvous/channel_deriver.dart`
- `packages/libreshare_core/lib/src/rendezvous/envelope_codec.dart`
- `packages/libreshare_core/lib/src/rendezvous/rendezvous_service.dart`
- `packages/libreshare_core/lib/src/rendezvous/rendezvous_candidate_source.dart`
- `packages/libreshare_core/test/conformance/rendezvous_schema_test.dart`

## Test Files (to copy to packages/libreshare_core/)
- `test/conformance/rendezvous_schema_test.dart`
- `test/unit/rendezvous/contracts_test.dart`
- `test/unit/rendezvous/schema_test.dart`

## Quality Check
- `git apply --check -p1 patch.diff` exits 0.
- `dart analyze --fatal-infos` exits 0.
- `dart format --output=none --set-exit-if-changed .` exits 0.
- All 11 unit tests in `test/unit/rendezvous/` pass 3x.
- All rendezvous conformance tests in `test/conformance/rendezvous_schema_test.dart` pass 3x.
- Pre-existing conformance tests (`schema_conformance_test.dart`, `lsp11_conformance_test.dart`, `lsp11_vectors_test.dart`) pass 100% unchanged.
