# R4e tests-plan (tester, 2026-11-06 14:05): regression pin, no lib change (orchestrator answer Q3 = option 3)

Clone: `.toolchain/scratch/e5-r4e/clone` (unchanged lib/). New file: `packages/libreshare_core/test/security/manifest_limit_order_test.dart` (copy in this folder). Uses the existing `P3Rig` (secure ApiServer, fake handler).
Pins LSP-1 4.3 secure-profile order: the 10,000-file limit is decided after the proof verifies.

| test | guard | result on unchanged tree |
|---|---|---|
| premise | 10,001-file body is above 256 KiB and below the 4 MiB cap | green |
| file-limit-after-auth-no-proof | 10,001 files, no X-LS-Auth -> 401 AUTH_INVALID (not 413), handler untouched | green |
| file-limit-after-auth-bad-proof | proof signed for another body -> 401 | green |
| file-limit-after-auth-garbage-proof | malformed X-LS-Auth -> 401 | green |
| file-limit-enforced | same body correctly signed -> 413 TOO_LARGE, retryable false, no session created | green |
| file-limit-boundary | exactly 10,000 files signed -> 202 | green |
| file-limit-after-auth-replay-not-spent | after the unsigned 401 a signed request still works | green |

Command (3 runs, alone under the heavy lock): `cd clone/packages/libreshare_core && flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/security/manifest_limit_order_test.dart`
- run1 `+7: All tests passed!` rc=0 (13:59:51); run2 rc=0 (14:01:59); run3 rc=0 (14:04:02).
Mutation checks (move the count before the proof / drop the 413) were NOT run by the tester; that is the verifier's job: expected red are the three `...-after-auth-*` tests for the first mutation and `file-limit-enforced` for the second.
