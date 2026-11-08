# R4d report (coder, 2026-11-06)
Change: `packages/libreshare_core/lib/src/discovery/peer_registry.dart` only (patch.diff, ~30 lines). Source of a certificate = address of the listed peer whose fingerprint equals it; shared "unknown" bucket when no peer is listed OR when MORE THAN ONE deviceId claims the fingerprint (round 2, verifier F1: a public fingerprint must not let an attacker steer attribution; fallback 2 chosen because the engine callbacks `onCertificate: (der)` carry no transport source, so an optional `source` parameter would need engine edits). New `maxCertsPerSource = 64` (public static const, tests do not need it); global `_maxCertMemory = 1024` unchanged. Over its cap a source evicts its own oldest; then the global LRU applies. Bookkeeping: `_certSource` (fp -> source, one per stored cert) and `_certSourceCount` (counter removed at 0); both released in `_dropCert` on any eviction/refresh, so bounded by 1024 entries. Peer removal does not drop certs (unchanged behaviour: certs outlive presence, needed for bye verification).

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

## Round 2 (verifier F1 fix), 2026-11-06 20:52-22:27
Change: `_sourceOf` returns the unknown bucket if a second deviceId claims the same fingerprint. Verifier tests copied into the clone's test/unit unchanged. All under `flock -o /tmp/libreshare-heavy.lock`:
- P6 file: rc=0 (+1), 20:52-20:58 (was red).
- Tester file 3x: rc=0, rc=0, rc=0 (+7 each), 20:58-21:31.
- Verifier probes file: rc=0 (+10), 21:31-21:53.
- Registry/discovery files (multicast, peer_registry, goodbye, announce_fingerprint, raw_multicast, contacts_only, p6b, remove): rc=0, +142, 21:53-21:55.
- `dart analyze --fatal-infos` and `dart format --output=none --set-exit-if-changed` on peer_registry.dart: rc=0 and rc=0.
- Full core `dart test -j 1`: rc=0, +2625 ~1 (2614 + P6 + 10 probes), 21:57-22:21.
- CLI suite (`dart test -j 1` in the clone's packages/libreshare_cli): rc=1, +75 -1, only `loopback_smoke_secure_test` ("does not contain 'SAS '"). Cause: the clone is an older snapshot of the tree (its tools/loopback_smoke.sh and cli lib differ from the real tree, `diff` confirms); the same test file in the REAL tree passes (rc=0, +2, 22:22). Not related to peer_registry; the other 75 CLI tests pass. Not re-verified against a patched real tree (nothing applied there).
- `patch -p1 --dry-run` of patch.diff on a copy of the real peer_registry.dart: rc=0.
Residual of the fallback: a victim whose cert is learned while an attacker alone has claimed the fingerprint is still attributed to the attacker until a second claimant appears (attacker must be listed before the victim and announce the victim's fingerprint before the victim is heard); the verifier's P6 order is covered.

## Known limits (verifier F2-F5, not fixed)
- F2: many-source floods still win (17 addresses x 64 certs, or about 1015 sources, flush the memory; global LRU is by age).
- F3: the shared unknown bucket (64 slots) can be flushed (certs learned before the peer is listed).
- F4: a rotated certificate leaves the old one stored until evicted.
- F5: a stale address label stays after a peer changes address, until the cert is relearned.

## Round 3 (F6/F7 fix), 2026-11-07 15:15-15:58
Change: `_sourceOf(fp, subjectCn)`: a cert is attributed to `_peers[subjectCn]` only if that entry exists and its fingerprint equals the cert's; otherwise the unknown bucket. Forged claimants (other deviceIds) are ignored; O(1), no new maps (all bookkeeping still <= 1024). F8 (relabel on remove/address change) not done: not cheap in this design, stays a known limit. Clone re-synced to the current real peer_registry.dart + old patch, then edited.
Results (clone, under flock, rc captured separately):
- analyze --fatal-infos lib file rc=0; format --set-exit-if-changed rc=0.
- P6 file rc=0 (+1).
- r2 file rc=1, +7 -3: R2-A2, R2-B4, R2-C3 fail ONLY on `expect(label, '')`; actual label is '10.1.0.1' (the victim's own address, i.e. better than the shared bucket). The attack tests (A1, B2, C2, A3...) pass. These assertions contradict F7; tests not touched, verifier/tester must flip them.
- Tester file 3x rc=0, rc=0, rc=0 (+7 each).
- Registry/discovery files rc=0.
- Not run this round (not requested): full core suite, CLI suite, probes file.
