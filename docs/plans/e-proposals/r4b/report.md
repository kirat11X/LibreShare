# R4b coder report (2026-11-06)

Change: `MulticastDiscovery._handleBye(bye, source)` in `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart` (patch.diff, ~45 lines, only this file).
After the existing cheap checks (window, listed+fingerprint, certificate, replay) and BEFORE `_takeByeBudget`, a source with >= 2 failed verifications in the last sliding second is dropped. A failed verify records (source, now). Genuine byes never record anything, so goodbye_test (7 valid byes from one source -> 5) is unchanged.

## Numbers (for the user's decision)
- 2 failed verifications per source per second (max 2 of the 5/s budget burnt by a forger; 3 stay for others).
- Recovery: sliding 1 s window, no ban; a flooding source keeps getting 2 verifies/s.
- Table bound: 256 sources; expired entries purged on overflow, then oldest evicted. Spoofed-source floods remain a documented non-goal (backed by 90 s expiry).

## Evidence
Red before (tester): bye_flood_test +4 -2 (rc=1, 10:34:50). Green after: 6/6.
| command | rc | time |
|---|---|---|
| dart test -j 1 test/security/bye_flood_test.dart (first run) | 0 | 12:13:09 |
| same, 3x | 0,0,0 | 12:14-12:22 |
| dart test -j 1 test/security test/discovery | 1 | 12:25 ("loading test/discovery": that directory does not exist; the security + unit goodbye/discovery tests ran in the full run) |
| dart test -j 1 (packages/libreshare_core) | 0 | 12:36: +2597, ~1 skipped |
| dart analyze --fatal-infos | 2 | 12:36: 1 warning, `test/security/bye_flood_test.dart:26 unused_import libreshare_core.dart` (tester's file; I may not edit it. Lib code is clean) |
| dart format --output=none --set-exit-if-changed (changed lib file) | 0 | 12:36 |

## Risks
- A forger sharing an IP with a legit peer (NAT) can delay that peer's bye by up to 1 s windows (bye is best effort, 90 s expiry backs it).
- A legit peer whose bye fails twice (e.g. stale cert) is muted for 1 s: harmless.
- Needs tester action: remove the unused import in bye_flood_test.dart for analyze to pass.

## Round 2 (2026-11-06, orchestrator request)
Added to `MulticastDiscovery` (plus `import 'package:meta/meta.dart' show visibleForTesting;`, meta is already a core dependency):
`@visibleForTesting int get byeFailureSourceCount => _byeFailures.length;` (read-only, lets a verifier test the 256-source cap without dart:mirrors). Nothing else changed; no per-fingerprint cap.
Gates (clone): bye_flood_test 3x rc=0 (+6 each, 20:59-21:31); test/unit/goodbye_test.dart rc=0 (+26, 21:53); `dart analyze --fatal-infos lib` rc=0 "No issues found" (21:53; the tester file's unused import was not part of this check); `dart format --output=none --set-exit-if-changed` on multicast_discovery.dart rc=0. patch.diff regenerated against the real tree; `patch -p1 --dry-run` on a copy of the real lib file rc=0.
Residual limit (documented, not fixed): 3 or more distinct forging source addresses can still exhaust the shared 5/s verify budget, because each source may fail 2 verifications per second and an attacker can name any listed fingerprint, so a per-fingerprint cap would not close it; byes then fall back to the 90 s expiry.
