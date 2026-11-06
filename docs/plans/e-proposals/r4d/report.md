# R4d report (coder, 2026-11-06)
Change: `packages/libreshare_core/lib/src/discovery/peer_registry.dart` only (patch.diff, ~30 lines). Source of a certificate = address of the listed peer whose fingerprint equals it (else shared "unknown" bucket). New `maxCertsPerSource = 64` (public static const, tests do not need it); global `_maxCertMemory = 1024` unchanged. Over its cap a source evicts its own oldest; then the global LRU applies. Bookkeeping: `_certSource` (fp -> source, one per stored cert) and `_certSourceCount` (counter removed at 0); both released in `_dropCert` on any eviction/refresh, so bounded by 1024 entries. Peer removal does not drop certs (unchanged behaviour: certs outlive presence, needed for bye verification).

## Red then green
Red: tester run 2026-11-06 12:08:58 rc=1 (+3 -4). Green (dart test -j 1, new file), rc=0 each: 12:13-12:15 (first), 12:16:10-12:18:58, 12:18:58-12:21:30, 12:21:30-12:24:06 (3x runs, all +7).
## Gates (clone/packages/libreshare_core, under flock)
- `dart test -j 1 test/unit test/discovery` 12:24-12:32 rc=1: only because `test/discovery` does not exist ("Failed to load"); 1589 tests ran before, none failed. Rerun 13:51-13:54 same result. `test/unit` content is covered by the full run.
- `dart test -j 1` (whole package) 12:32:28-12:45:24 rc=0, +2614 ~1 (2607 + 7 new, 1 skipped).
- `dart analyze --fatal-infos` (changed files) 12:45-12:50 rc=0. `dart format --output=none --set-exit-if-changed` (changed files) 12:50-12:54 rc=0.
## Numbers for the user's decision
64 per source / 1024 global (tests accept 8..512). One source can hold 6.25% of memory; 16 hostile sources can still fill the global memory (inherent to a source-based cap; sources are spoofable addresses on LAN UDP).
## Risks
- Source lookup scans `_peers` (<= maxPeers) per learn: O(n), only on learn.
- Source is the address at learn time; a peer that changes address keeps old label until relearned.
- Per-source eviction scans `_certs` (<=1024) only when over cap.
- Spoofed-address floods (many sources) are not stopped; global LRU still applies.
