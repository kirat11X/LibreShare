# R4d verifier report (verifier, 2026-11-06; run 13:55-15:47, finished 20:46)

Verdict: **SAFE AFTER FIXES** (one MEDIUM fix wanted before this is relied on; the patch is a strict improvement over today's tree and has no regression).
Scratch: `.toolchain/scratch/e5-r4d-verify/{clone,mut,logs}`. Logs and my tests are copied to `verifier-tests/`. Real tree untouched. Line numbers refer to `peer_registry.dart` after the patch.

## 1. Diff read line by line
- **Source of a cert** (`_sourceOf`, 240-248): the address of the FIRST entry in `_peers` (insertion order) whose `info.fingerprint` equals the cert's, else the shared `''` bucket (`_unknownSource`, 70). Attribution is fixed at learn time (223-227).
- **Cert learned before its peer is listed**: goes to the unknown bucket (capped at 64 total) and is NOT relabelled when the peer is listed later (nothing in `seen`); it only moves on the next `learnCertificate` of the same fp. Probe P1b: legit certs sitting there are lost to an unknown-bucket flood (0/10 survive).
- **Peer changes address**: the cert keeps the old address label until re-learned (the engine re-learns only when `certificateFor(fp) == null`, so usually never). Bounded, no leak; the old label may be shared with another host later (harmless).
- **Two peers on one address (NAT)**: they share one 64-slot budget; a noisy neighbour can evict its neighbour's oldest cert. Acceptable (stated in report.md).
- **Peer removed / swept**: certs are not dropped (unchanged behaviour, needed for bye verification); bookkeeping stays bounded by the cert count (P3c).
- **Bookkeeping release**: `_certs` is only ever shrunk through `_dropCert` (223 refresh, 229 per-source eviction, 232 global eviction); `_dropCert` (250-259) removes `_certSource[fp]` and decrements/removes `_certSourceCount`. No other removal path exists (dispose does not clear, as before). Verified by P3: after 20,000 learns `_certs = _certSource = 1024`, `_certSourceCount = 961` buckets, sum of counts = 1024, max per bucket 64, key sets identical.
- **Per-learn scan**: `_sourceOf` is O(listed peers) with one `toUpperCase()` + compare each; worst case 1024 peers (default `maxPeers`) = 1024 string ops per learn. The per-source eviction `firstWhere` is O(<=1024) map lookups, only when the source is over its cap. Measured P5: 20,000 learns = 182,650 ms with 0 listed peers vs 185,932 ms with 1024 listed peers, i.e. +164 us per learn (about 1.8% of the ~9.1 ms per learn that the P-256 self-signature verify already costs). Bound stated: < 0.2 ms extra per learn at 1024 peers.
- A `StateError` from `firstWhere` (229) cannot occur while the two maps stay consistent (P3 consistency check); it would be swallowed by `on Object` and leave the cert stored over cap. Not reachable.

## 2. Gates (fresh clone of the current tree, patch rc=0, one process at a time under the heavy lock)
| gate | start-end | result | rc |
|---|---|---|---|
| patch -p1 | 13:55 | applied cleanly | 0 |
| cert_cache test, run 1 | 13:59:51-14:01:47 | +7 | 0 |
| run 2 | 14:02:03-14:03:58 | +7 | 0 |
| run 3 | 14:04:15-14:06:10 | +7 | 0 |
| 9 registry/discovery files (multicast_discovery, peer_registry, multicast_probe, peer_registry_remove, goodbye, announce_fingerprint, raw_multicast, contacts_only_discovery, p6b_review) | 14:08:56-14:09:07 | +174 | 0 |
| `dart test -j 1` core | 14:13:45-14:18:48 | +2614 ~1 (2607 + 7, 1 skipped) | 0 |
| `dart analyze --fatal-infos` (clone root) | 14:24:51 | No issues found | 0 |
| `dart format --output=none --set-exit-if-changed .` (root) | 14:27:02 | 319 files, 0 changed | 0 |
| grep `package:flutter|dart:ui` in core lib | 14:18 | no match | 1 (expected) |

## 3. Mutation table (second copy `mut/`, tester's test file, 7 tests; each restored, `diff -r` of lib and `diff` of test rc=0; final `diff -r` lib and test against clone rc=0)
| mutant | run | result | tests red |
|---|---|---|---|
| a remove per-source cap | 15:17:48 | +3 -4 rc=1 KILLED | per-source-cert-cap, per-source-cert-cap-bound, other-sources-survive, unlisted-fingerprint-bucket |
| b cap 64 -> 100000 | 15:19:43 | +3 -4 rc=1 KILLED | same four |
| c source key = constant | 15:21:36 | +3 -4 rc=1 KILLED | per-source-cert-cap, other-sources-survive, global-bound-intact, unlisted-fingerprint-bucket |
| d evict newest of source (lastWhere) | 15:23:31 | +6 -1 rc=1 KILLED | per-source-cert-cap-bound |
| e bookkeeping not released in `_dropCert` | 15:25:26 | +2 -5 rc=1 KILLED | per-source-cert-cap, -bound, other-sources-survive, new-source-still-accepted, relearn-refreshes |
| f remove global cap 1024 | 15:26:35 | +6 -1 rc=1 KILLED | global-bound-intact |
| g unknown bucket unbounded | 15:28:35 | +6 -1 rc=1 KILLED | unlisted-fingerprint-bucket |
No survivor. (`logs/summary.txt` contains one stale `mut-a rc=0` line from an aborted first attempt that ran on an already restored file; ignore it, the table above is from `mut-summary.txt`.)

## 4. Probes (`verifier-tests/peer_registry_cert_cache_verifier_probes_test.dart`, +10, rc=0, 14:43-15:03; pool of 5000 real certs, mirrors read the private maps)
- **P1** unknown-bucket flood of 5000 certs: legit certs of 10 listed addresses 10/10 survive (total stored 74 = 10 + 64).
- **P1b** (honest residual) legit certs learned before listing, i.e. in the unknown bucket: 0/10 survive the same flood.
- **P2** 5000 distinct (spoofed) addresses: legit survivors after N distinct-address certs: 16 -> 10, 500 -> 10, 1000 -> 10, 1014 -> 10, 1015 -> 9, 5000 -> 0. **P2b**: 17 sources x 64 certs (1088) already evict 10/10 (0 survive). The source cap does not protect against an attacker owning 17 addresses (IPv6 or IP aliases make that cheap); the global LRU is by age only.
- **P3** 20,000 learns mixed: all bookkeeping <= 1024 and consistent (numbers in section 1). **P3b** unknown flood: 64 certs, 1 bucket. **P3c** 300 peers listed then removed: 192 certs (3 sources x 64), maps consistent.
- **P4** key rotation (same deviceId, new cert, same address): new cert stored and attributed, `fingerprintChanged` raised; the OLD cert is not released, it stays (count for the address 2) until evicted by cap or LRU. Re-learning the same cert does not double count.
- **P5** cost: see section 1 (+164 us per learn at 1024 peers).
- **P6** fingerprint borrowing (defect, see F1): `peer_registry_cert_cache_verifier_p6_test.dart`, run 15:47:01, rc=1 as expected ("Expected: not null, Actual: null").

## 5. Findings
- **F1 MEDIUM - source attribution can be hijacked.** `_sourceOf` takes the first listed peer that CLAIMS the fingerprint. A fingerprint is public (it is in every announce) and `seen()` accepts a second deviceId with the same fingerprint. An attacker listed before the victim (announces first, or the victim expired/was removed and is re-listed behind it) makes the victim's genuine cert count against the attacker's address; 65 certs from that one address then evict it (P6, and a single IP with 65 announced ports is enough because `_learnCertificate` connects to `d.address:d.info.port`). Effect: the victim's real signed bye is not verified, the peer lingers until expiry. Fix (best): give `learnCertificate` an optional `source` (the remote address of the TCP connection the cert was actually read from; the three engine call sites plus registrar/subnet_scanner callbacks know it). Registry-only mitigation: if more than one listed deviceId claims the fingerprint, use the unknown bucket; also consider refusing a second deviceId for an already claimed fingerprint in `seen` (protocol question, orchestrator). Keep `verifier-tests/..._p6_test.dart` as the regression test (red today).
- **F2 LOW/accepted residual - many-source floods** (P2, P2b): 17 addresses or 1015 sources flush the memory. Possible hardening: on global eviction pick the oldest entry of the source holding the most certs instead of the globally oldest; contacts' certs could also be exempted (pin from the trust store). Needs a decision, not a blocker.
- **F3 LOW - unknown bucket is shared** (P1b): certs learned before the peer is listed (subnet scanner path) are in a 64-slot bucket any scanned host set can flush. Fix: relabel a cert when `seen` lists its fingerprint, or learn after listing.
- **F4 LOW - rotation leaves the old cert** (P4): harmless (bounded by caps), but `seen` with a changed fingerprint could drop the previous cert once the user accepts the new one (`acceptFingerprint`).
- **F5 LOW - stale address label** after an address change (section 1). Same relabel-on-seen fix as F3.
