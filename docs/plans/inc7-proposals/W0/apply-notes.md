# Apply Notes: Card W0 (Increment 7 Wave 0)

## Modified Files
1. `packages/libreshare_core/lib/src/connection/candidate.dart`
   - Added `CandidateKind.hotspot('hotspot', defaultCostHint: 15)`.
   - Added `setupBudget`, `connectBudget`, `setup()`, and `teardown()` hooks to base `Candidate`.
   - Added `HotspotRole` enum and `HotspotCandidate` class.

## New Files
1. `docs/plans/inc7-seams.md`
2. `docs/protocol/ble/schemas/ble-m1.schema.json`
3. `docs/protocol/ble/schemas/ble-m2.schema.json`
4. `docs/protocol/ble/schemas/ble-auth.schema.json`
5. `docs/protocol/ble/schemas/ble-offer.schema.json`
6. `docs/protocol/ble/schemas/ble-decision.schema.json`
7. `docs/protocol/ble/schemas/ble-netplan.schema.json`
8. `docs/protocol/ble/schemas/ble-hotspot.schema.json`
9. `docs/protocol/ble/schemas/ble-joined.schema.json`
10. `packages/libreshare_core/lib/src/ble/beacon_types.dart`
11. `packages/libreshare_core/lib/src/ble/ble_backend.dart`
12. `packages/libreshare_core/lib/src/ble/ble_contracts.dart`
13. `packages/libreshare_core/lib/src/ble/ble_messages.dart`
14. `packages/libreshare_core/lib/src/ble/hotspot_backend.dart`
15. `packages/libreshare_core/test/unit/ble/contracts_test.dart`
16. `packages/libreshare_core/test/unit/ble/schema_test.dart`

## Application Instructions
Apply `patch.diff` with `-p0` from repository root:
```bash
patch -p0 < docs/plans/inc7-proposals/W0/patch.diff
mkdir -p packages/libreshare_core/test/unit/ble
cp docs/plans/inc7-proposals/W0/test/contracts_test.dart packages/libreshare_core/test/unit/ble/
cp docs/plans/inc7-proposals/W0/test/schema_test.dart packages/libreshare_core/test/unit/ble/
```
