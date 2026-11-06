# R4b tests-plan (tester, 2026-11-06 10:36)

Clone: `.toolchain/scratch/e5-r4b/clone`. New file only: `packages/libreshare_core/test/security/bye_flood_test.dart` (copy here). No API change needed; it uses the existing harness (`P6bNode`, in-memory bus, `ManualClock`, `rawBye`).
File the coder edits: `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart` (`_handleBye`, `_takeByeBudget`); `announce_codec.dart` needs no change.

## Finding (what is really open)
The cheap pre-checks the card asks for ALREADY exist in `_handleBye` (window, listed with exactly this fingerprint, certificate held, replay) and run before `_takeByeBudget`. The real hole is a forged bye that names a LISTED peer with its public fingerprint and a well-formed (wrong) signature: it passes every cheap check and spends one of the 5 global verifications; 20/s per source get past the packet limiter, so one source burns the whole budget each second.
Constraint from existing tests (cannot be edited): `goodbye_test` 'verification_budget_5_per_second' (7 VALID byes from ONE source -> exactly 5 verified) and 'the budget is global, not per source'. So a per-source cap on all byes is wrong. The tests therefore demand per-source accounting of FAILED verifications (a source whose byes fail verification is cut off before the verify after a few failures; suggested: at most 2 failures per source per second, with a way back after the quiet period). Spoofed-source floods (each forged bye from another address) are a documented non-goal; the best-effort bye is backed by the 90 s expiry.

## Tests (GUARD names in the descriptions)
| test | guard | now |
|---|---|---|
| per-source-failed-verify-limit | 3 s of 1000 forged byes/s from one source; genuine byes from 3 other sources at 0.5/1.5/2.5 s are each processed within 1 s; victim never removed | RED |
| per-source-failed-verify-limit-same-second | burst of 200 forgeries then a genuine bye in the same second is verified | RED |
| pre-verify-checks-stay-cheap | 1000 forgeries from 1000 sources (unknown id / wrong fingerprint / no certificate) leave all 5 verifications free (budget is the oracle: no verify-counter seam exists or is needed) | green (pin; mutation: `_takeByeBudget` moved before the cheap checks -> RED, shown below) |
| global-budget-unchanged | 7 valid byes from one source -> exactly 5 honoured | green (guards against an over-eager per-source cap) |
| flood-source-not-banned-forever | after the flood and 10 s quiet the same source's genuine bye is honoured | green (guards against a permanent ban) |
| forged-bye-never-honoured | flood naming every listed peer removes nobody | green (safety) |

## Commands
1. `cd clone/packages/libreshare_core && flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/security/bye_flood_test.dart` -> rc=1 (2026-11-06 10:34:50), `+4 -2`: the two RED tests above ("Expected: true Actual: false: genuine bye at 0.5 s of the flood" / "Expected: false Actual: true: verified within the second").
2. Mutation check of the pin test in a throwaway copy (`.toolchain/scratch/e5-r4b/mutcheck`, `_takeByeBudget` moved to the first line of `_handleBye`): rc=1 (10:35:02), `+3 -3`, `pre-verify-checks-stay-cheap` goes red as intended.

## Lint fix (tester, 2026-11-06 13:57): unused import only
Removed the unused `import 'package:libreshare_core/libreshare_core.dart';` (line 26) from `bye_flood_test.dart`; no assertion, name, count or behaviour changed; lib/ untouched. Copy in this folder updated. Commands in `clone/packages/libreshare_core` (real rc):
- `flock -o /tmp/libreshare-heavy.lock dart analyze --fatal-infos` -> "No issues found!" analyze_rc=0 (13:55:49; no other info or warning in any file)
- `dart format --output=none --set-exit-if-changed test/security/bye_flood_test.dart` -> format_rc=0
- `flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/security/bye_flood_test.dart` -> `+6: All tests passed!` test_rc=0 (13:57:12)
