# R4b verifier report (forged signed-bye flood), verifier agent, 2026-11-06

Patch under test: `docs/plans/e-proposals/r4b/patch.diff` (only `discovery/multicast_discovery.dart`), applied with the R4c patch to a FRESH clone of the current real tree (`.toolchain/scratch/e5-r4bc-verify/clone`, `patch -p1` rc 0 for both). Tester file re-copied from the proposal folder at the start (identical to the folder copy; the unused import is STILL there, see gate table).

## Verdict: SAFE TO APPLY (updated in round 2: the tester file is lint-clean now and analyze/format are rc 0; the original verdict was SAFE AFTER FIXES only because of that unused import)
The lib patch itself is safe to apply. The only red gate is `dart analyze --fatal-infos` rc 2 caused by the tester's `bye_flood_test.dart:26:8 unused_import` (tester file, not edited by me). Remove that import line (the file compiles without it: my own verifier file had the same unused import and compiles after deleting it) and the gate is green. Honest residual limit: 3 distinct forging source addresses still starve the shared budget (section Probes).

## Gate table (clone, each alone under `flock -o /tmp/libreshare-heavy.lock`)
| gate | result | rc | time |
|---|---|---|---|
| `dart test -j 1 test/security/bye_flood_test.dart` run 1 / 2 / 3 | +6 / +6 / +6, all passed | 0 / 0 / 0 | 12:46:04 / 12:50:52 / 12:57:50 |
| `dart test -j 1 test/unit/goodbye_test.dart` (untouched) | +26 all passed | 0 | 13:01:02 |
| `dart test -j 1` packages/libreshare_core (with R4b + R4c patches and both new test files) | +2618, ~1 skipped, -1 failed = exactly `regreet-after-restart` (R4c, red by design Q4). 2618 = 2607 baseline + 6 + 5 | 1 | 13:04:51 |
| `dart test -j 1` packages/libreshare_cli | +76 -1: `loopback_smoke_secure_test` "completes TLS transfer with SAS verification". First run failed only because the clone had no `.toolchain/` dir (snapshot path), then, with the dir created, failed again on `Expected: contains 'SAS '` while the transfer itself printed COMPLETED. The SAME test also fails when run alone in the REAL, unpatched tree (13:56-13:59), so it is not caused by these patches (environment/ordering; the CLI does not touch `_handleBye`). Not investigated further; the orchestrator should re-check the CLI baseline (77) on a quiet machine | 1 | 13:06:02 and 13:55:48 |
| `dart analyze --fatal-infos` at clone root | 1 issue: `test/security/bye_flood_test.dart:26:8 unused_import` (tester file); lib clean | 2 | 13:06:10 |
| `dart format --output=none --set-exit-if-changed .` at clone root | 0 changed (320 files) | 0 | 13:06:14 |
| `grep -RnE "package:flutter\|dart:ui" packages/libreshare_core/lib` | no match | 1 (expected) | 12:39 |

## Code review of the diff (line by line)
- Cheap checks (window, listed + exact fingerprint, certificate held, replay) are untouched and still run before everything else. The new per-source test is inserted AFTER the replay check and BEFORE `_takeByeBudget` (so a cut-off source does not even spend the budget: mutation f proves the order matters).
- Replay memory (`_lastByeTs`) is still written only after `verifySignature` returned true; the failure record is written only on a failed verify.
- The shared 5/s sliding budget code is unchanged. Valid byes never record anything, so `goodbye_test` (7 valid byes from one source -> 5 honoured, budget global) still passes (+26).
- Failure records are keyed by the UDP source address string (same key as the packet limiter). Entries are lazily purged per source; on overflow (>256) expired ones are swept and then the oldest-inserted is evicted. Measured: with 5 verified failures per second from ever-new sources for 80 s the table peaked at 255 entries (400 without the cap, mutation g).
- Can someone else force a failure record for a LEGITIMATE peer? Only by sending forged byes with that peer's source address (UDP source spoofing, possible on a LAN). Measured: 2 forged byes per second spoofed from the legitimate peer's address mute that address's genuine byes indefinitely (each 1 s window), and it recovers one second after the spoofer stops. This is not worse than before the patch (a real-source flood of 5/s already starved everybody), and a bye is best-effort (90 s expiry). Not a regression; documented below as LOW.
- Residual limit (measured, `bye_flood_verifier_test.dart` RESIDUAL-LIMIT): genuine bye honoured with 1 or 2 forging sources, NOT honoured with 3 or more (each source burns 2 of the 5 verifications per second). So the patch removes the single-source flood of the card (1000/s) but a rotating or spoofed set of 3 source addresses at about 6 packets/s still starves legitimate byes. The pre-patch bar was 1 source.
- NAT: legitimate peers behind one IP share the failure account; a forger behind the same NAT mutes their byes (same as the spoof case).

## Mutation table (second copy `.toolchain/scratch/e5-r4bc-verify/mut`, one at a time; after each the lib was restored and `diff -r` clone vs mut lib returned rc 0). Tests run: tester file + my verifier files.
| # | mutation | red test(s) | |
|---|---|---|---|
| a | remove the per-source check | tester `per-source-failed-verify-limit`, `per-source-failed-verify-limit-same-second` | killed |
| b | threshold 2 -> 1000 | same two tester tests | killed |
| c | never record a failure | same two tester tests | killed |
| d | permanent window (no recovery) | tester `flood-source-not-banned-forever` | killed |
| e | one global key for all failures | tester `per-source-failed-verify-limit`, `-same-second` | killed |
| f | budget taken BEFORE the per-source check | tester `per-source-failed-verify-limit`, `-same-second` | killed |
| g | remove the 256-source cap | none of the tester tests (SURVIVED) ; killed only by my `FAILURE-TABLE-BOUNDED` (table 400 > 256) | test gap closed by verifier test |
Note: the tester's own `pre-verify-checks-stay-cheap` pin was shown red by the tester for "budget before the cheap checks"; I did not repeat that mutation.

## Verifier tests (copies in `docs/plans/e-proposals/r4b/verifier-tests/`)
- `bye_flood_verifier_test.dart` (4 tests: RESIDUAL-LIMIT measurement, SHARE-EXACTLY-2, SPOOFED-SOURCE side effect, NO-FAILURE-RECORD-FOR-CHEAP-REJECTS). Plain Dart, analyze/format clean; suitable for the tree.
- `bye_flood_table_verifier_test.dart` (1 white-box test using `dart:mirrors` to read the private `_byeFailures`). It passes with `dart test` but `dart analyze` in this repo reports `dart:mirrors` as unavailable, so it must NOT go into the analyzed tree as is. Alternative for the orchestrator: add a `@visibleForTesting int get byeFailureSources` getter to `MulticastDiscovery` (lib change, not mine to make) and rewrite the test to use it.
Results on the patched clone: see the log lines at the end of this file.

## Findings
- MEDIUM (residual, honest): 3 distinct source addresses starve the shared 5/s budget (measured). Fix options: (1) additionally cap failed verifications per NAMED FINGERPRINT (e.g. 2 per second per `bye.fingerprint`), which bounds the burn per victim regardless of how many addresses the forger rotates; (2) at least write the number 3 into the "known limits" of LSP-1 rule 9 / inc3 section 12 next to the 2-failures/s/source sentence. Not a blocker for this item (spoofed sources were declared a non-goal by the tester/orchestrator).
- LOW: spoofed-source muting of a legitimate address (2 packets/s mutes it); no worse than before.
- LOW: tester file unused import (blocks `dart analyze --fatal-infos`); delete line 26.
- LOW: failure table eviction is insertion-ordered not LRU and entries are swept only on overflow or when the same source returns; bounded at 256 so harmless.
- INFO: the CLI smoke failure above is independent of this patch.

## Final verifier-test runs on the patched clone (formatted/linted versions)
`dart test -j 1 test/security/bye_flood_verifier_test.dart test/security/bye_flood_table_verifier_test.dart` -> rc 0, +5 all passed (20:55:35). Printed: residual map `{1: true, 2: true, 3: false, 4: false, 5: false, 6: false}`; failure table max length 255 (cap 256) over 400 sources. Raw logs: `verifier-tests/gates.log`, `verifier-tests/mutation.log`.

## Round 2 (2026-11-06 21:53-21:57): tests converted, no `dart:mirrors`
Setup: fresh clone `.toolchain/scratch/e5-r4b-verify3/clone` of the current real tree; the regenerated `r4b/patch.diff` (mtime 21:53:23, adds `@visibleForTesting int get byeFailureSourceCount => _byeFailures.length;`) applied with `patch -p1` rc 0. Test files copied into `packages/libreshare_core/test/security/`: the tester's folder copy `bye_flood_test.dart` (mtime 13:57, no unused import), `bye_flood_verifier_test.dart`, and the converted `bye_flood_table_verifier_test.dart` (reads `rx.discovery.byeFailureSourceCount`; same name and same assertion `max table length <= 256`). Fixes to my files: removed an unused import from the table test and a stale `dart:mirrors` comment from `bye_flood_verifier_test.dart`.
| command (clone, one at a time under `flock -o /tmp/libreshare-heavy.lock`) | result | rc | time |
|---|---|---|---|
| `dart analyze --fatal-infos` on the patched `multicast_discovery.dart` + the 3 test files | No issues found (the tester file is now lint-clean) | 0 | 21:54 |
| `dart format --output=none --set-exit-if-changed` on the same 4 files | 0 changed | 0 | 21:54 |
| `dart test -j 1 test/security/bye_flood_test.dart` (tester, 6 tests) | +6 all passed | 0 | 21:55:44 |
| `dart test -j 1 test/security/bye_flood_verifier_test.dart` | +4 all passed | 0 | 21:55:47 |
| `dart test -j 1 test/security/bye_flood_table_verifier_test.dart` x3 | +1 each; 400 sources seen, max table length 255 (<= 256) each time | 0,0,0 | 21:55:52 / 21:55:57 / 21:56:02 |
| mutation g (256-source cap removed) on the converted table test | `FAILURE-TABLE-BOUNDED` red, max table length 400 > 256; lib restored, `diff -r` clone vs mut lib rc 0 | 1 | 21:56:12 |
| `grep -n "import 'dart:mirrors'"` over `test/security/bye_flood*` | none | 1 | 21:54 |
Logs: `verifier-tests/round2.log`, `.toolchain/scratch/e5-r4b-verify3/`. The mirror-based predecessor is kept as `verifier-tests/bye_flood_table_verifier_test.dart.mirrors-OLD` (not a `.dart` file, do not apply).

**Test files to apply with the R4b patch (all in `packages/libreshare_core/test/security/`, none uses `dart:mirrors`):**
1. `docs/plans/e-proposals/r4b/bye_flood_test.dart` (tester file, 6 tests)
2. `docs/plans/e-proposals/r4b/verifier-tests/bye_flood_verifier_test.dart` (4 tests: residual-limit measurement, exact 2-of-5 share, spoofed-source side effect, no failure record for cheap rejects)
3. `docs/plans/e-proposals/r4b/verifier-tests/bye_flood_table_verifier_test.dart` (1 test, uses the new getter)
Expected added tests: +11 in `test/security`. With these, all seven mutations a-g of the table above are killed (g by file 3).
