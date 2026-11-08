# E5 acceptance (orchestrator, alone-run, 2026-11-07 17:27)

Real tree = commit c5080ca + the working-tree changes listed below. Every number comes from a log under `.toolchain/scratch/` with the exit code captured on the line right after the command (the older gate scripts captured `$?` after a `date` substitution and always showed rc 0; every older result was re-read from its log).

| Item | State | Verifier | Gate evidence |
|---|---|---|---|
| R1a | closed, no lib change (regression test kept) | tester | - |
| R1b atomic files | applied (user committed) | 3 rounds, `verifier-patch-r1b-only.diff` | per-patch gate green; **regression found by the full gate**: `d1b_sender_dialog`, `d1v_retry_guard` (see below) |
| R1c/R1d paths, launcher | applied (committed) | verifier | green |
| R4a connection cap | applied 2026-11-07 17:08 as `verifier-patch-r4a-with-r3.diff` (coder patch + the verifier's ClientHello check) | 3 rounds, SAFE AFTER FIXES, fix included | tester 3x +12, probes 3x +18, round2 3x +6, round3 3x +13, 19 related files, analyze/format rc 0 |
| R4b bye flood | applied (committed) | verifier | green |
| R4c greeting retry | applied (committed) | verifier | green |
| R4d cert cache | applied 17:08 | 3 rounds, SAFE (3 documented low limits L1-L3) | tester 3x +7, p6 3x +1, r2 3x +10, r3 3x +10, rc 0 |
| R4e manifest limit order | applied (tests only) | verifier | green |
| R1b follow-up (`transfers_provider.dart`) | applied 17:09 | coder + orchestrator review | fixes the regression: `d1b_sender_dialog` +7, `d1v_retry_guard` +2 |

## The R1b regression (my miss)
The per-patch R1b gate ran only the new test files, not the app suite. The first full app run (gate 2) failed 3 tests; alone reruns failed 3/3. Bisect on a clean `fcaf3ba` extract (`.toolchain/scratch/bisect/`): `fcaf3ba` passes; `fcaf3ba` + R1b alone fails; reverting only `file_secret_store.dart` passes; removing the per-target queue, the stale-tmp check or the post-commit delete one at a time does not fix it. Cause: `writeFileAtomically` now delegates to `atomicWriteBytes` (more async hops); in the FakeAsync widget tests that exposes a 2 s `Timer` that outlives its provider in `TransfersNotifier._drive`. Fix: the backstop is now a Timer owned by `_drive`, cancelled when the notifier is disposed (the registration is removed in `finally`). Rule from now on: every lib patch gets the full core, CLI and app suites before it counts as applied.

## Full gate after all changes (log: `.toolchain/scratch/gate-final/`)
| Step | Result |
|---|---|
| core `dart test` | rc 0, `+2915 ~2` |
| app `flutter test` | rc 0, `+548` |
| CLI `dart test` | rc 1, `+76 -1`: `cli_commands_test` "real processes over real multicast devices finds a running receiver and send --device delivers to it". Not caused by E5: it fails identically on a clean `fcaf3ba` extract; manual repro shows `ls devices` finds the receiver but `ls send --device` does not. Handed to the Lead (STATUS.md, card Q-CLI-DISCOVERY). |
| `dart analyze --fatal-infos` | rc 2, 168 issues: 167 in the Lead's `scratch_*` files and root `test_*` files, 1 real info at `receive_mode_engine_test.dart:332` (`unawaited_futures`), which comes from the Lead's weakened version of that test (`blocker.close()` no longer awaited) and disappears when the original is restored |
| `dart format --set-exit-if-changed .` | rc 1, 42 files, none of them E5/K1 code: the Lead's `port_blocker.dart` helpers (2) and unformatted `.dart` files in the Lead's `docs/plans/*-proposals/` folders |

## Other results of this session
- K1 (phone "not enough free space"): applied 17:04, tests green (core +5 x3, app +4 x3, schema/LSP-1 conformance, related files), mutation check by the orchestrator: never-classify and always-classify are killed, the case-sensitivity mutant survives (the receiver message is lowercase). New value `STORAGE_UNUSABLE` added to `docs/protocol/schemas/session-status.schema.json` and LSP-1.md (the conformance test requires schema == `FailureReason.values`). Limit: the sender classifies by the word "folder" in the 507 message.
- Q-RESTORE: all six original tests pass on the current code (3 passes each); see `post-commit-test-edits-20261106.md`.
