# Card K0 Apply Notes

## Summary
Introduces Increment 5b contracts, data models, and contract tests for port mapping, gateway discovery, and direct network path candidates.

## Target Files
- `docs/plans/inc5b-seams.md`
- `packages/libreshare_core/lib/src/nat/gateway_info.dart`
- `packages/libreshare_core/lib/src/nat/origin_kind.dart`
- `packages/libreshare_core/lib/src/nat/port_mapper.dart`
- `packages/libreshare_core/lib/src/nat/port_mapping.dart`
- `packages/libreshare_core/lib/src/nat/reachability_probe.dart`
- `packages/libreshare_core/test/unit/nat/contract_test.dart`

## Application Instructions
```bash
patch -p1 < docs/plans/inc5b-proposals/K0/patch.diff
cp -a docs/plans/inc5b-proposals/K0/test/unit/nat packages/libreshare_core/test/unit/
```

## Verification Steps
```bash
dart analyze --fatal-infos packages/libreshare_core/lib/src/nat/ packages/libreshare_core/test/unit/nat/contract_test.dart
dart test packages/libreshare_core/test/unit/nat/contract_test.dart
```
