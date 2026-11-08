# Apply Notes: Card A3 (Increment 7 Wave A3)

## Prerequisites
Requires Card W0 (`docs/plans/inc7-proposals/W0/`), Card A1 (`docs/plans/inc7-proposals/A1/`), and Card A2 (`docs/plans/inc7-proposals/A2/`).

## Modified Files
1. `packages/libreshare_core/lib/src/discovery/device_discovery.dart`
   - Added `ble` to `DiscoverySource` enum.
2. `packages/libreshare_core/lib/src/ble/ble_contracts.dart`
   - Exported `ble_coordinator.dart`.
3. `packages/libreshare_core/lib/src/ble/testing/fake_ble_bus.dart`
   - Automatically registers GATT server on `start()` and unregisters on `stop()`.
4. `packages/libreshare_core/lib/src/engine/discovery_config.dart`
   - Added `bleBackend`, `bleVisibility`, `advKey`, and `onBleTransferPrompt` options.
5. `packages/libreshare_core/lib/src/engine/libreshare_engine.dart`
   - Wires `BleCoordinator` into engine lifecycle (`start()` / `stop()`) and exposes `bleCoordinator` getter.

## New Files
1. `packages/libreshare_core/lib/src/ble/ble_coordinator.dart`
2. `packages/libreshare_core/test/unit/ble/a3_engine_ble_test.dart`

## Application Instructions
Apply `patch.diff` with `-p0` from repository root:
```bash
patch -p0 < docs/plans/inc7-proposals/A3/patch.diff
cp docs/plans/inc7-proposals/A3/test/a3_engine_ble_test.dart packages/libreshare_core/test/unit/ble/
```
