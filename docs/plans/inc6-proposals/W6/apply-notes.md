# Card W6 Apply Notes

## Affected Files
Production files:
- `apps/libreshare_app/lib/widgets/pair_dialog.dart` (new)
- `apps/libreshare_app/lib/widgets/paired_peers_card.dart` (new)
- `apps/libreshare_app/lib/widgets/relay_settings_card.dart` (new)

Test files:
- `apps/libreshare_app/test/widgets/paired_peers_test.dart` (new)
- `apps/libreshare_app/test/widgets/relay_settings_test.dart` (new)

## Patch Application Instructions
1. Apply patch to root workspace:
   ```bash
   patch -p0 < docs/plans/inc6-proposals/W6/patch.diff
   ```
2. Copy test files:
   ```bash
   mkdir -p apps/libreshare_app/test/widgets
   cp docs/plans/inc6-proposals/W6/test/paired_peers_test.dart apps/libreshare_app/test/widgets/
   cp docs/plans/inc6-proposals/W6/test/relay_settings_test.dart apps/libreshare_app/test/widgets/
   ```
3. Run verification:
   ```bash
   flutter test --no-pub apps/libreshare_app/test/widgets/paired_peers_test.dart apps/libreshare_app/test/widgets/relay_settings_test.dart
   ```
