# Card K3 Apply Notes

## Summary
Introduces `DirectOriginServer` using ephemeral TLS certificates, `DirectConnection` with SHA-256 fingerprint certificate pinning, `CandidateRace` for staggered connection priority resolution, and `ShareLink` extensions for `d` (candidates) and `pin` (ephemeral certificate fingerprint).

## Target Files
- `packages/libreshare_core/lib/src/nat/direct_origin_server.dart`
- `packages/libreshare_core/lib/src/connection/direct_connection.dart`
- `packages/libreshare_core/lib/src/connection/candidate_race.dart`
- `packages/libreshare_core/lib/src/share/share_link.dart`
- `packages/libreshare_core/test/unit/nat/direct_origin_pin_test.dart`
- `packages/libreshare_core/test/unit/nat/candidate_race_test.dart`
- `packages/libreshare_core/test/unit/nat/link_d_pin_conformance_test.dart`

## Application Instructions
```bash
patch -p1 < docs/plans/inc5b-proposals/K3/patch.diff
cp docs/plans/inc5b-proposals/K3/test/unit/nat/* packages/libreshare_core/test/unit/nat/
```

## Verification Steps
```bash
dart analyze --fatal-infos packages/libreshare_core/lib/src/nat/ packages/libreshare_core/lib/src/connection/ packages/libreshare_core/lib/src/share/ packages/libreshare_core/test/unit/nat/
dart test packages/libreshare_core/test/unit/nat/
```
