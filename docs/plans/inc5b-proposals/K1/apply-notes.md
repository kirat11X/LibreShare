# Card K1 Apply Notes

## Summary
Adds pure, table-driven IP classification (`ip_classify.dart`), RFC 5389 STUN discovery client (`stun_client.dart`), and connection-oriented reachability probe (`reachability_probe_impl.dart`).

## Target Files
- `packages/libreshare_core/lib/src/nat/ip_classify.dart`
- `packages/libreshare_core/lib/src/nat/stun_client.dart`
- `packages/libreshare_core/lib/src/nat/reachability_probe_impl.dart`
- `packages/libreshare_core/test/unit/nat/ip_classify_test.dart`
- `packages/libreshare_core/test/unit/nat/stun_client_test.dart`
- `packages/libreshare_core/test/unit/nat/reachability_probe_test.dart`

## Application Instructions
```bash
patch -p1 < docs/plans/inc5b-proposals/K1/patch.diff
cp docs/plans/inc5b-proposals/K1/test/unit/nat/* packages/libreshare_core/test/unit/nat/
```

## Verification Steps
```bash
dart analyze --fatal-infos packages/libreshare_core/lib/src/nat/ packages/libreshare_core/test/unit/nat/
dart test packages/libreshare_core/test/unit/nat/
```
