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

---

# Round 2 (verifier re-check of the F1 fix, 2026-11-06 22:28 - 2026-11-07 15:12)

**Verdict: SAFE AFTER FIXES.** The round-1 attack (P6) is closed and nothing regressed, but the new rule opens a cheaper targeted variant (B2 below) and leaves the "attacker alone claims first" residual (A1). One small registry-only fix (F7) removes both.

Patch under test: `r4d/patch.diff`, 1 file section (`grep -c '^--- '` = 1), `peer_registry.dart` only. Scratch: `.toolchain/scratch/e5-r4d-verify2/{clone,mut,clone3}`; logs copied to `verifier-tests/round2/`.

## Gates (all heavy runs alone under `flock -o /tmp/libreshare-heavy.lock`, TMPDIR in repo `.toolchain/tmp`)
| step | when | result | rc |
|---|---|---|---|
| fresh clone `clone` (tree of 11-06 22:29) + `patch -p1` | 22:29 | applied | 0 |
| tester file run 1 / 2 / 3 | 22:31-22:37 | +7 / +7 / +7 | 0 / 0 / 0 |
| P6 file | 22:37 | +1 (was red in round 1) | 0 |
| r2 file (new, 10 tests) | 22:37 | +10 | 0 |
| 9 registry/discovery files | 22:37 | +174 | 0 |
| probes file (round 1, 10 tests, about 18 min) | 23:06:49-23:25:04 | +10 | 0 |
| `dart analyze --fatal-infos` lib file + tester file; and at clone root | 22:37 | No issues | 0 / 0 |
| `dart format --output=none --set-exit-if-changed` lib file + tester file | 22:37 | 0 changed | 0 |
| verifier files: `dart analyze --fatal-infos` + `dart format --set-exit-if-changed` (3 files together) | 22:3x | No issues / 0 changed | 0 / 0 |
| re-check on a NEWER fresh clone `clone3` (rsync with `--exclude='scratch_*' --exclude='test_c_*' --exclude='/test_*.dart'`, now with R4b/R4c): patch | 15:09 | applied, result `cmp` identical to the round-2 clone file | 0 / 0 |
| `clone3`: tester file / P6 / r2 | 15:09-15:12 | +7 / +1 / +10 | 0 / 0 / 0 |
| `clone3`: `dart analyze --fatal-infos` at root | 15:12 | 1 info in `test/integration/receive_mode_engine_test.dart:332` (unawaited_futures; R4c area, NOT R4d) | 1 |
| `clone3`: `dart format` lib file + tester file | 15:12 | 0 changed | 0 |
Also: current real `peer_registry.dart` + new patch (dry-run and real, in `drycheck/`) gives a file byte-identical to the one tested (`cmp` rc 0), so R4b/R4c changes elsewhere do not touch the patched module. Full suites skipped as instructed (coder reports +2625 ~1; I did not re-run).
Note: the verifier files now carry `// ignore_for_file: avoid_print, uri_does_not_exist, ...` (dart:mirrors is unknown to the analyzer but works under `dart test`) so they pass `--fatal-infos`; probes file also got a block-braces fix; behaviour unchanged.

## Mutation table (copy `mut/`; tests run: tester file + P6 file + r2 file = 18 tests; each restored, `diff -r` lib rc 0, final `diff -r` test rc 0)
| mutant | result | tests red (short) |
|---|---|---|
| h revert `_sourceOf` to first-claimant | +14 -4 KILLED | P6 (source-attribution-not-hijackable), R2-A2, R2-B4, R2-C3 |
| i 2+ claimants treated as the first | +14 -4 KILLED | same four |
| j unlisted -> per-fp bucket (drop unknown path) | +17 -1 KILLED | unlisted-fingerprint-bucket |
| k ambiguity -> per-fp bucket instead of unknown | +15 -3 KILLED | R2-A2, R2-B4, R2-C3 (the P6 file alone does NOT catch k) |
| a no per-source cap | +14 -4 KILLED | per-source-cert-cap, -bound, other-sources-survive, unlisted-fingerprint-bucket |
| b cap 64 -> 100000 | +14 -4 KILLED | same four |
| c constant source key | +5 -13 KILLED | 13 tests |
| d evict newest of source | +17 -1 KILLED | per-source-cert-cap-bound |
| e bookkeeping not released | +3 -15 KILLED | 15 tests |
| f no global cap | +17 -1 KILLED | global-bound-intact |
| g unknown bucket unbounded | +17 -1 KILLED | unlisted-fingerprint-bucket |
No survivor (11/11). Mutant k is only killed by my r2 tests, so r2 is needed in the apply list.

## Break attempts (`verifier-tests/peer_registry_cert_cache_verifier_r2_test.dart`)
- **P6 / round-1 F1: CLOSED.** Probes P6 (inside the probes file) now: cert attributed to `""`, alive after 65 attacker certs = true; P6 file green.
- **(a) Residual, attacker alone claims first (R2-A1, R2-A3):** the attacker lists one deviceId with the victim's fingerprint; the victim's cert is learned BEFORE the victim is listed; it is attributed to the attacker address (`10.66.6.6`) and 70 attacker certs from that address evict it: **victim cert LOST**. What is lost is exactly the certs whose fingerprint the attacker alone claims before the cert is learned (A3: contacts 0-2 claimed -> lost, contacts 3-5 not claimed -> kept; A1: 6/6 unclaimed contacts survive). Fingerprints are public (every announce carries one), so "bounded to what the attacker can name" bounds nothing for an attacker who watches the LAN, but it needs the unlisted-learn timing: the engine learns after the peer is listed, so only the scanner / greet paths hit it. If the victim is listed afterwards and its cert relearned, the label moves to the unknown bucket and the flood no longer touches it (R2-A2: alive).
- **(b) Forged claimants push a victim into the shared unknown bucket (R2-B1..B4):**
  - B1 no relearn: an existing victim cert keeps its own label and survives, even with 70 ambiguous attacker certs (unknown bucket = 64).
  - **B2 (attack works):** victim listed and cert stored; attacker lists ONE extra deviceId with the victim fingerprint; the victim cert is relearned (R4c greet retries / registrar / scanner do this) -> label `""`; the attacker then announces 64 own certs, each under two deviceIds (128 listings, so each is ambiguous and lands in the same unknown bucket): the 64th evicts the victim cert. **Needed: 1 forged claimant + 128 listings + a victim relearn; no ordering requirement.** Compared with the original tree (1024 distinct certs from anywhere) this is CHEAPER for a targeted attack; compared with the round-1 P6 (1 claimant first + 65 certs) it is similar cost without the ordering constraint. B3: with single-claimed attacker certs (not ambiguous) the victim in the unknown bucket survives. B4: 50 forged claimants cost no extra bookkeeping (certs=1, label `""`).
  - Untargeted floods are still contained: contacts of other sources survive (A1, B1, B3).
- **(c) Registry churn (R2-C1..C3):** C1 claimant removed: label stays `""` (stale) until relearn, then moves to `10.1.0.1`; no leak. **C2:** sole claimant (attacker) removed and the victim listed: label stays attacker address until relearn, a 70-cert attacker flood still evicts the victim cert (stale attribution is exploitable only while it lasts; relearn fixes it). C3: victim removed and re-listed behind the claimant: stays safe (two claimants). All maps stayed consistent and <= 1024 in every test (`consistent()` helper: key sets equal, counts sum to cert count).
- Bookkeeping, scan cost: unchanged from round 1; probes P3/P5 re-run: certs=1024, certSource=1024, buckets=961; 20,000 learns 181,453 ms (0 peers) vs 184,264 ms (1024 peers), +141 us per learn. The new `_sourceOf` still scans all peers once (no early exit when the first match is found, by design to find a second claimant): same O(peers) bound.

## Findings (round 2)
- **F6 MEDIUM - shared unknown bucket is attacker-controllable via forged claimants (B2).** A victim can be demoted from its own bucket into the 64-slot shared bucket with one forged deviceId, then flushed with 64 ambiguous certs. Fix choices: (1) F7 below, or (2) minimal: map ambiguity to a per-fingerprint bucket (mutant k's behaviour: `if (claimant != null && claimant != e.key) return fp;`), so forged claimants can no longer put the victim into a shared bucket; the flood then costs about 1024 certs again (same as the original tree). Tests R2-A2/B4/C3 assert the current `""` rule and would need the tester's decision (they are verifier tests, adjust together with the fix).
- **F7 (recommended, registry-only, not prototyped) - count only claimants whose deviceId equals the certificate subject CN.** `learnCertificate` already parses the cert (`cert.subjectCn`, which `cert_factory.dart:429` sets to the deviceId and `key_identity.dart:86` enforces). In `_sourceOf(fp, cn)` ignore listed entries whose key (deviceId) != cn; source = that entry's address, else the unknown bucket. A forged claimant ("evil-claimant" with the victim fingerprint) then has the wrong deviceId and is invisible: A1, B2 and C2 stop working, the ambiguity case disappears (one key per deviceId), P6 stays closed. Residual: an attacker announcing the victim's own deviceId (ordinary discovery spoofing, out of R4d scope).
- **A1 residual (MEDIUM/LOW)** is the same root cause; F7 closes it. If not fixed, document it as the coder did.
- **F8 LOW:** stale attribution after claimant removal / address change (C1, C2) lives until the next relearn; relabel in `seen`/`remove` or accept.
- F2-F5 of round 1 unchanged.

## Exact list of verifier files to apply (all into `packages/libreshare_core/test/unit/`)
1. `r4d/peer_registry_cert_cache_test.dart` (tester, 7 tests, about 2 min)
2. `r4d/verifier-tests/peer_registry_cert_cache_verifier_p6_test.dart` (1 test, 5 s)
3. `r4d/verifier-tests/peer_registry_cert_cache_verifier_r2_test.dart` (10 tests, about 10 s; includes mutant-k killers; R2-A1/B2/C2 print the residual outcomes and assert only invariants, so they stay green on the current patch; if F7/F6 is adopted, flip them to assert survival)
4. `r4d/verifier-tests/peer_registry_cert_cache_verifier_probes_test.dart` (10 tests, about 18 min, memory/scan probes; optional for the normal gate, keep out of the default suite if 18 min is too long)
Expected with 1-3: core suite 2614 + 1 + 10 = +2625 passed at the baseline of that day (plus other items' tests), 1 skipped; with 4 add 10.

---

# Round 3 (verifier re-check of the F6/F7 fix, 2026-11-07 15:59 - 16:55)

**Verdict: SAFE** (with three documented limits, none of them a regression against the original tree: F3 shared unlisted bucket, F8 stale address label, R3-6 victim-deviceId address spoof). The round-1 attack (P6), the round-2 residual A1, the targeted attack B2 and the stale-claimant case C2 are closed; all 15 mutants are killed except 2 that I judge equivalent or observably neutral.

Patch: `r4d/patch.diff`, 1 section (`grep -c '^--- '` = 1). New rule: `_sourceOf(fp, cert.subjectCn)` = address of `_peers[subjectCn]` only if that entry exists and its fingerprint equals the cert's, else the shared unknown bucket. Fresh clone `.toolchain/scratch/e5-r4d-verify3/{clone,mut}` of the CURRENT tree (rsync excludes `scratch_*`, `test_c_*`, root `test_*.dart`), `patch -p1` rc 0 in both, patched file `cmp` identical in both copies. Logs in `verifier-tests/round3/`.

## (1) The three flipped assertions in `peer_registry_cert_cache_verifier_r2_test.dart` (nothing else in the file changed except the test names/comments of those three)
The attack scenario of each test is untouched; only the `expect(label(victim), ...)` line changed from `''` (shared unknown bucket) to `'10.1.0.1'` (the victim's own address).
- **R2-A2** (attacker claims victim fp, victim listed afterwards, cert relearned, 70-cert attacker flood): label `'' -> '10.1.0.1'`. The old value encoded the round-2 rule "two claimants -> shared bucket". Under the CN rule the owner is the entry whose deviceId equals the cert CN, the claimant is invisible, so the cert belongs to the victim's own bucket. That is the intended outcome (the whole point of F7) and strictly stronger: the cert now sits in a 64-slot bucket the attacker cannot reach. The attack assertion `expect(has(victim), isTrue)` after the flood is unchanged and still has to hold.
- **R2-B4** (50 forged claimants with the victim fp): same flip, same reason; forged ids can no longer demote the cert to the shared bucket (that demotion was the B2 mechanism). `consistent()` and `certs = 1` unchanged.
- **R2-C3** (victim removed and re-listed behind the claimant): the pre-removal label `'' -> '10.1.0.1'`; `has(victim)` after the flood is unchanged.
Not a weakening: a mutant that restores the old rule (h, i) goes red on exactly these tests (table below), so they still discriminate; the flipped label is the more demanding expectation.

## (2) Gates (single files, under the heavy lock, real rc from the logs)
| step | when | result | rc |
|---|---|---|---|
| tester file run 1 / 2 / 3 | 16:04:29 - 16:10:11 | +7 / +7 / +7 | 0 / 0 / 0 |
| P6 file | 16:10 | +1 | 0 |
| r2 file (3 flips applied) | 16:10 | +10 | 0 |
| r3 file (new, first version) / final version (R3-6 strengthened) | 16:10 / 16:54 | +10 / +10 | 0 / 0 |
| 9 registry/discovery files | 16:10:52 | +174 | 0 |
| `dart analyze --fatal-infos` lib file + tester file + p6/r2/r3 | 16:10:45 | No issues found | 0 |
| `dart format --output=none --set-exit-if-changed` same 5 files | 16:10:45 | 0 changed | 0 |
| `dart analyze --fatal-infos` clone root (verifier files present by a cleanup slip of my script, harmless) | 16:10:52 | 1 issue: `test/integration/receive_mode_engine_test.dart:332` unawaited_futures (R4c file, not R4d) | 1 |
| final r3 analyze + format | 16:54 | No issues / 0 changed | 0 / 0 |
The 18-minute probes file (P1-P5) and full suites were not re-run, as instructed; the CN rule is O(1) per learn (hash lookup) instead of the O(peers) scan, and every r2/r3 test calls `consistent()` (key sets equal, counts sum to cert count, all maps <= 1024).

## (3) Mutation table (copy `mut/`, 28 tests = tester 7 + p6 1 + r2 10 + r3 10; each restored, `diff -r` lib rc 0; final `diff -r` lib and test between clone and mut rc 0)
| mutant | result | red tests (short) |
|---|---|---|
| h revert to round-1 first-claimant scan | +22 -6 KILLED | P6, R2-A2, R2-C3, R3-1, R3-4, R3-5 |
| i round-2 rule (claimants by fp, 2+ -> unknown) | +21 -7 KILLED | R2-A2, R2-B4, R2-C3, R3-1, R3-2, R3-4, R3-5 |
| j not-listed / mismatch -> per-fp bucket (drop shared unknown path) | +22 -6 KILLED | unlisted-fingerprint-bucket, R3-10, R3-1, R3-4, R3-5, R3-8 |
| n1 ignore subjectCn, trust the claimed fingerprint | +22 -6 KILLED | P6, R2-A2, R2-C3, R3-1, R3-4, R3-5 |
| n2 skip the fingerprint-equality check | +26 -2 KILLED | R3-5, R3-10 |
| n3 always unknown | +8 -20 KILLED | 20 tests |
| n4 drop the `subjectCn == null` guard | +28 SURVIVES: EQUIVALENT (`Map[null]` is null-safe, returns unknown either way) |
| n5 address taken from `info.addrs.first` when present | +28 SURVIVES: observably neutral in these tests (`P6bPeer.info()` has no addrs; a representation change, not an attribution change); not worth a test |
| a no per-source cap | +23 -5 KILLED | other-sources-survive, per-source-cert-cap, -bound, unlisted-fingerprint-bucket, R3-4 |
| b cap 64 -> 100000 | +23 -5 KILLED | same five |
| c constant source key | +6 -22 KILLED | 22 tests |
| d evict newest of source | +26 -2 KILLED | per-source-cert-cap-bound, R3-5 |
| e bookkeeping not released | +4 -24 KILLED | 24 tests |
| f no global cap | +27 -1 KILLED | global-bound-intact |
| g unknown bucket unbounded | +26 -2 KILLED | unlisted-fingerprint-bucket, R3-4 |
Mutants n2 (fingerprint check) and n1 (CN ignored) are the two new-rule guards; each is killed by named tests (R3-5/R3-10 and P6/R3-1/R3-4/R3-5).

## (4) Retries and new break attempts (`peer_registry_cert_cache_verifier_r3_test.dart`, final run 16:54, +10)
| id | attack | outcome |
|---|---|---|
| R3-1 (A1) attacker alone claims the victim fp, victim cert learned before the victim is listed, 70-cert flood from the attacker address | CLOSED: cert goes to the shared bucket (label `''`), survives; after the victim is listed and the cert relearned the label is the victim address |
| R3-2 (B2) 1 forged claimant + relearn + 70 double-claimed attacker certs | CLOSED: label stays `10.1.0.1`, victim alive; the attacker's ambiguous certs fill the unknown bucket (64) but the victim is not in it |
| R3-3 (C2) sole claimant removed, victim listed later | CLOSED: victim alive after the flood |
| R3-4 attacker certs whose CN is not a listed deviceId (80) | land in the unknown bucket (exactly 64 kept), listed victim untouched |
| R3-5 70 attacker keys with a cert CN equal to the victim's deviceId | listed entry has another fingerprint -> unknown bucket, victim cert untouched |
| R3-6 attacker announces the victim's own deviceId + fp from its address | no relearn: label stays, victim alive. With a relearn while the spoofed address is listed the cert follows the listed (attacker) address and 70 distinct attacker certs evict it (alive=false). RESIDUAL, see L3 |
| R3-7 (F8) victim moves to a new address; attacker sits at the OLD address | label stays old; 70 attacker certs from the old address evict the cert (alive=false). RESIDUAL, see L2 |
| R3-8 victim cert learned while the victim is not listed (scanner order) | sits in the shared bucket; 70 unlisted attacker certs flush it (alive=false). RESIDUAL = F3, see L1 |
| R3-9 victim removed (bye/sweep) | cert and label stay, flood from the attacker does not evict it |
| R3-10 listed fingerprint differs from the cert (rotated key not yet announced) | not attributed to the address (unknown bucket) |

## Limits left (all documented, none worse than the original tree's 1024-cert flush except where stated)
- **L1 = F3 (LOW):** certs learned while their peer is not listed share the 64-slot unknown bucket. An attacker needs the engine to learn 64+ of ITS certs unlisted (only the subnet-scanner path does that; attacker would have to answer scans as 64 hosts or ports), so it is not a cheap flood. Fix if wanted: attribute on `seen` (relabel) or learn after listing.
- **L2 = F8 (LOW, judged ACCEPTABLE as a documented limit):** after an address change or a peer's disappearance the label is the address at learn time. An attacker can exploit it only from the victim's OLD address (DHCP reuse, same NAT); anyone at the same address can already use the shared 64-slot budget under any source-address scheme, and the next relearn moves the cert. A relabel in `seen` would cost an O(certs) scan per address change; not worth it.
- **L3 (LOW):** a host that announces the victim's own deviceId AND fingerprint (plain discovery spoof) becomes the owner while it is listed. In the engine the learn path connects to the listed address and requires `fingerprintHex(der) == announced fp` (`libreshare_engine.dart` `_learnCertificate`), which the spoofer cannot satisfy without the victim's key, so the relearn that R3-6 assumes does not happen through that path. Residual only when a cert arrives from another path (scanner at the real address) while the spoofed entry is listed. Out of R4d scope (discovery identity spoofing).
- F2 (many-source floods: 17 addresses or about 1015 sources flush the global memory) and F4 (rotation leaves the old cert) unchanged.

## (5) Apply list (checked against `apply-notes.md`)
`apply-notes.md` is correct for the patch and for p6; it must be updated (orchestrator's call, I did not edit it) as follows. Copy into `packages/libreshare_core/test/unit/`:
1. `r4d/peer_registry_cert_cache_test.dart` (7 tests, about 2 min)
2. `r4d/verifier-tests/peer_registry_cert_cache_verifier_p6_test.dart` (1)
3. `r4d/verifier-tests/peer_registry_cert_cache_verifier_r2_test.dart` (10; the three flips are now in the file, all green)
4. `r4d/verifier-tests/peer_registry_cert_cache_verifier_r3_test.dart` (10; new, about 15 s)
5. optional: `r4d/verifier-tests/peer_registry_cert_cache_verifier_probes_test.dart` (10, about 18 min; keep out of the default gate)
The note "3 of its tests ... are RED ... need the verifier to flip" can be deleted. Expected additions to the core suite with 1-4: 7 + 1 + 10 + 10 = 28 tests (2635 on the baseline of 2607 that the earlier numbers used, plus whatever other items added), +10 with the probes file. The verifier files carry `// ignore_for_file` lines so `dart analyze --fatal-infos` and `dart format --set-exit-if-changed` pass on them (checked above).
