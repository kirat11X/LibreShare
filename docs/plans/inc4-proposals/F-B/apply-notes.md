# F-B Apply Notes

## Scope
Card F-B: FR-13 mid-transfer connection ladder fallback + D6 security pin check across ladder and fallback candidates.

## Files Touched
- `packages/libreshare_core/lib/src/engine/libreshare_engine.dart`
- `packages/libreshare_core/lib/src/engine/outgoing_send.dart`
- `packages/libreshare_core/lib/src/transfer/file_sender.dart`

## Acceptance Tests (pre-existing, unedited)
- `packages/libreshare_core/test/integration/ladder_fault_test.dart`
- `packages/libreshare_core/test/security/ladder_pin_test.dart`
- `packages/libreshare_core/test/integration/chunk_retry_integrity_test.dart`
- `packages/libreshare_core/test/unit/inc4_negatives_test.dart`

## Verification Command
```bash
patch -p1 --dry-run < docs/plans/inc4-proposals/F-B/patch.diff
# rc=0
```
