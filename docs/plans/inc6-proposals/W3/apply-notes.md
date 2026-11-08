# Card W3 Apply Notes

**Files modified by patch.diff:**
1. `packages/libreshare_cli/lib/ls_cli.dart`

**New test files to place:**
1. `docs/plans/inc6-proposals/W3/test/pairing_rendezvous_test.dart` -> `packages/libreshare_core/test/unit/rendezvous/pairing_rendezvous_test.dart`
2. `docs/plans/inc6-proposals/W3/test/peers_cli_test.dart` -> `packages/libreshare_cli/test/peers_cli_test.dart`

**Verification command:**
```bash
patch -p1 < docs/plans/inc6-proposals/W3/patch.diff
cp docs/plans/inc6-proposals/W3/test/pairing_rendezvous_test.dart packages/libreshare_core/test/unit/rendezvous/pairing_rendezvous_test.dart
cp docs/plans/inc6-proposals/W3/test/peers_cli_test.dart packages/libreshare_cli/test/peers_cli_test.dart
dart test packages/libreshare_core/test/unit/rendezvous/pairing_rendezvous_test.dart packages/libreshare_cli/test/peers_cli_test.dart
```
