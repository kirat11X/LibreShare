# Apply Notes: Card A2 (Increment 7 Wave A2)

## Prerequisites
Requires Card W0 (`docs/plans/inc7-proposals/W0/`) and Card A1 (`docs/plans/inc7-proposals/A1/`).

## Modified Files
1. `packages/libreshare_core/lib/src/ble/ble_contracts.dart`
   - Added exports for `ble_crypto.dart` and `ble_session.dart`.

## New Files
1. `packages/libreshare_core/lib/src/ble/ble_crypto.dart`
2. `packages/libreshare_core/lib/src/ble/ble_session.dart`
3. `packages/libreshare_core/test/unit/ble/a2_ble_session_test.dart`

## Application Instructions
Apply `patch.diff` with `-p0` from repository root:
```bash
patch -p0 < docs/plans/inc7-proposals/A2/patch.diff
cp docs/plans/inc7-proposals/A2/test/a2_ble_session_test.dart packages/libreshare_core/test/unit/ble/
```
