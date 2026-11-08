# Apply Notes: Card A1 (Increment 7 Wave A1)

## Prerequisites
Requires Card W0 (`docs/plans/inc7-proposals/W0/`).

## Modified Files
1. `packages/libreshare_core/lib/src/ble/ble_contracts.dart`
   - Added exports for `beacon_codec.dart`, `visibility_manager.dart`, `gatt_frame_codec.dart`, and `testing/fake_ble_bus.dart`.

## New Files
1. `packages/libreshare_core/lib/src/ble/beacon_codec.dart`
2. `packages/libreshare_core/lib/src/ble/gatt_frame_codec.dart`
3. `packages/libreshare_core/lib/src/ble/visibility_manager.dart`
4. `packages/libreshare_core/lib/src/ble/testing/fake_ble_bus.dart`
5. `packages/libreshare_core/test/unit/ble/a1_beacon_codec_test.dart`

## Application Instructions
Apply `patch.diff` with `-p0` from repository root:
```bash
patch -p0 < docs/plans/inc7-proposals/A1/patch.diff
cp docs/plans/inc7-proposals/A1/test/a1_beacon_codec_test.dart packages/libreshare_core/test/unit/ble/
```
