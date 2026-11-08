# Verifier Report: Card W0 (Increment 7 Wave 0)

## Mutation Testing
| Mutation ID | File | Line | Description | Test Result | Status |
|---|---|---|---|---|---|
| M1 | `packages/libreshare_core/lib/src/ble/beacon_types.dart` | 134 | Omit magic check in `fromBytes` | `contracts_test.dart` line 52 FAILS (`Expected: null, Actual: BleBeacon`) | KILLED |
| M2 | `packages/libreshare_core/lib/src/ble/ble_messages.dart` | 91 | Corrupt `BleM1.type` to `'m1_bad'` | `schema_test.dart` line 56 FAILS (Schema validation rejects invalid type) | KILLED |
| M3 | `packages/libreshare_core/lib/src/connection/candidate.dart` | 305 | Invert `setupBudget` for join vs host | `contracts_test.dart` line 223 FAILS (`Expected: 0:01:30, Actual: 0:00:10`) | KILLED |
| M4 | `docs/protocol/schemas/ble-offer.schema.json` | 6 | Omit `totalSize` from required | `schema_test.dart` line 86 FAILS (Negative control expects validation failure) | KILLED |

## Flake Gate
Ran `dart test packages/libreshare_core/test/unit/ble/`:
- Run 1: 16/16 PASS (rc=0)
- Run 2: 16/16 PASS (rc=0)
- Run 3: 16/16 PASS (rc=0)
Flakes: 0 / 16.

## Quality Gates
- `dart format`: 0 changes needed (rc=0)
- `dart analyze`: 0 issues found (rc=0)
- Pre-gate compliance: 100% compliant with ADR 0002 and design 03.
