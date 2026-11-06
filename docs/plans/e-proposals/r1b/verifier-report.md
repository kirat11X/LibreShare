# R1b verifier report, version 2 (verifier agent; round 2 ran 14:20-15:16 by `date`)

Subject: the NEW `patch.diff` (14:20: only `storage/atomic_file.dart` changed against round 1). Fresh clone of the current real tree: `.toolchain/scratch/e5-r1b-verify2/clone` (rsync 14:21, `patch -p1 < patch.diff` rc=0, 5 files; tester files + `verifier-tests/*.dart` copied in). Mutation copy `.../mut`. Real tree untouched. Round 1 (old patch) is superseded; its raw data is in `.toolchain/scratch/e5-r1b-verify/`.

## Verdict: DO NOT APPLY YET - SAFE AFTER ONE FIX (R2-F1, HIGH)

Everything the round-1 findings asked for is fixed and green (F1-F4, F6; the 4 FINDING tests P1b/P2b/P3c/P4b pass). But the new "delete the backup after a successful commit" rule is applied on EVERY `atomicReplace`, including the plain-rename success path of `FileReceiver`, so it deletes a user file named `<received file>.bak` in the download directory. Proven by my test (below). One small, well-defined fix removes it; nothing else blocks.

## 1. Test updates (item 1)
Only P2a, P3a, P3b of `atomic_file_verifier_probes_test.dart` changed, to the new contract: P2a = link removed, other file untouched, target a regular file with the new bytes, listing `[other.txt, state.json]` (the old-code replica run is only printed); P3a = after the double failure the directory is exactly `[state.json.bak]`, target absent, `.bak` holds the old bytes; P3b = at the hang the directory is exactly `[state.json.bak, state.json.tmp]`, `.bak` holds the old bytes, no `.bak-<hex>`. Nothing else touched; tester files untouched. Note: P3c now passes trivially (its `.bak-` filter can no longer match anything); the real recovery checks are in the new V2 file.

## 2. Gates (fresh clone; every run alone under `flock -o /tmp/libreshare-heavy.lock`)
| Gate | Result | rc |
|---|---|---|
| tester files `atomic_file_test` + `atomic_file_adoption_test`, run 1 (14:25:40) | `+32 All tests passed` | 0 |
| run 2 (14:38:33) | `+32` | 0 |
| run 3 (15:09:17) | `+32` | 0 |
| my two files `atomic_file_verifier_probes_test` (20) + `atomic_file_verifier_mutation_test` (5) (15:09:22) | `+25 All tests passed` | 0 |
| my `atomic_file_verifier_v2_test` (20 tests) | 18 green, 2 red = the HIGH finding R2-F1 (intentional `FINDING` tests); kept OUT of the suite runs below | 1 |
| core `dart test -j 1` (15:09:22-15:13:04) | `+2664 ~1: All tests passed` (= 2607 + 32 tester + 25 verifier, 1 skipped) | 0 |
| cli `dart test -j 1` (15:13:04-15:14:26) | `+77: All tests passed` (the former unrelated red is fixed in the real tree) | 0 |
| `dart analyze --fatal-infos` at clone root, incl. all 3 verifier files | No issues found | 0 |
| `dart format --output=none --set-exit-if-changed .` root | 328 files, 0 changed | 0 |
| `grep -RnE "package:flutter\|dart:ui" packages/libreshare_core/lib` | no match | 1 (expected) |
| `tools/loopback_smoke.sh 100 53478` plain (15:14:26-15:14:35) | LOOPBACK OK, 100 MiB byte-identical, `17.6 MiB/s` (baseline 18, round 1 18.8; -2%, within the 20% budget) | 0 |

## 3. Mutation table (copy `mut/`, one at a time, restored, `diff -r` of lib+tests vs clone rc=0 for all 19 runs, no "MUTATION NOT APPLIED"; raw `verifier-tests/mutation-results.txt`)
Run over tester (2 files) + verifier (3 files). Baseline = only the 2 R2-F1 FINDING tests red. "Tester reds" = tests of the tester's two files that went red.

| # | Mutation | Tester reds | Killed by |
|---|---|---|---|
| a | rename straight onto target (no move-aside) | 6 | tester + V-restore, P3a/P3b/P5/P6, 5 V2 |
| b | delete old target before renaming | 6 | tester (never-delete x2, cleanup x4) + V-restore x2, P3, V2 |
| c | no restore when 2nd rename fails | 0 | V-restore x2, V2-first-error (SURVIVES the tester's tests) |
| d | skip tmp removal on failure | 8 | tester + V-restore, P1a/P3a/P6, V2 |
| e | skip stale-tmp removal | 0 | V-stale-tmp-readonly (SURVIVES the tester's tests) |
| f | drop the per-target queue | 1 | tester no-torn-reads, P4 x2, V2-queue-key |
| g | mode applied after the bytes | 0 | V-mode-before-bytes, P6 (SURVIVES the tester's tests) |
| h | bak/tmp litter after success (final `_deleteQuietly(bak)` removed) | 6 | tester replace-fallback x6, V-receiver, P5/P6, 5 V2 |
| i | receiver first final rename back to plain `rename` | 1 | tester receiver-final-move-uses-helper, V-receiver, P1c/P1d |
| i2 | receiver copy-fallback rename back to plain | 0 | V-receiver-copy-fallback-uses-helper (SURVIVES the tester's tests) |
| j | F1 filter removed (fallback also on EXDEV) | 0 | P1b, V2-F1-18, V2-F1-28 (SURVIVES the tester's tests) |
| k | F1 filter widened (errors WITHOUT osError also skip the fallback) | 0 | V2-F1-noerrno only (the tester's Windows-like hooks all carry errno 5, so they do NOT go red, contrary to the expectation; SURVIVES the tester's tests) |
| l | stale-bak removal before move-aside skipped | 0 | V2-stale-bak-removed (SURVIVES the tester's tests) |
| n | symlink-at-tmp deletion removed | 0 | P2a, P2b, V2-dangling-symlink-tmp (SURVIVES the tester's tests) |
| o | queue key not normalised | 0 | P4b, V2-queue-key-dotdot (SURVIVES the tester's tests) |
| p | `recoverAtomicBackup` restores although the target EXISTS | 0 | V2-recover-keeps-existing-target (SURVIVES the tester's tests; no tester test touches `recoverAtomicBackup` at all) |
| q | move-aside failure rethrows the move-aside error instead of the first | 0 | V2-first-error-moveaside (my first run of this table showed q SURVIVING everything; the new test kills it) |
| r | double-failure/second-rename path rethrows the later error | 0 | V2-first-error |
| (m) | "bak not removed after success" is the same code as h | | |

Survivors of the tester's tests: c, e, g, i2, j, k, l, n, o, p, q, r. All are killed by the verifier tests; the tester should adopt `atomic_file_verifier_mutation_test.dart` and `atomic_file_verifier_v2_test.dart` (minus the 2 FINDING tests until fixed).

## 4. Line-by-line review of the new diff (item 4)
- `_isHopeless` (EXDEV 18 / ENOSPC 28; Windows 17, 112, 39): correct values (NOT_SAME_DEVICE, DISK_FULL, HANDLE_DISK_FULL). It is a NEGATIVE filter: every other errno (EACCES 13, EROFS 30, EDQUOT 122, EIO 5, unknown, null) still runs the move-aside, so on POSIX the needless window remains for those (LOW; on POSIX the fallback is never needed at all, it exists only for the tests' errno-5 simulation and for Windows). EXDEV/ENOSPC verified: exactly 1 rename attempt, target never missing (V2-F1-18/-28).
- Fixed name `<target>.bak`: data-loss window now recoverable by `recoverAtomicBackup` (correct: restores only if the target is missing; V2-recover-* green) but NOT wired anywhere. Consequence: after a crash/double failure the store still `load()`s "missing" (defaults), the app then writes a fresh file, and the post-commit rule deletes the `.bak` - the old data is destroyed anyway (R2-F2, MEDIUM, Windows-reachable only).
- **Post-commit `_deleteQuietly(bak)` runs on every successful `atomicReplace`, even when no backup was made by this call, and the stale-bak delete before the move-aside also deletes whatever is at `<target>.bak`. In `file_receiver` the target directory is the USER's download folder: receiving `notes.txt` deletes the user's `notes.txt.bak` (R2-F1, HIGH, reproduced on plain Linux with no hook: V2-receiver-user-bak red).** The round-1 random backup name made a collision practically impossible; the fixed name makes it certain for anyone who keeps `.bak` files. The same applies to the Windows move-aside path.
- Symlink at tmp: `Link.delete` (correct, dangling links too; a directory still fails safely, P2c). 
- Queue key `p.normalize(p.absolute(...))`: fixes `./` and `sub/..`; still not canonical for symlinked directories or case-insensitive Windows paths (LOW).
- First error rethrown via `throw first` (loses the original stack trace; LOW). Verified by V2-first-error x2.
- `recoverAtomicBackup` is not queued with the writers: called while a writer is between the move-aside and the commit it would restore the old file under the writer's feet (on Windows the commit then fails and the writer restores again: no loss, but a spurious failure). Suggest running it through the same per-target queue (LOW).
- Target is a directory: rethrown before any move (V2-target-is-directory green: dir and child intact, no bak/tmp). `<target>.bak` being a directory: the delete is a no-op, plain replace works (V2-bak-is-directory green); on Windows-style refusal the move-aside would fail and the first error is thrown, so no loss.
- Double failure: old bytes in exactly one `<target>.bak`, target absent, tmp removed (P3a); crash while the commit hangs: `.bak` + `.tmp` (P3b); both are now repairable by `recoverAtomicBackup` (V2-recover-after-double-failure). A target-missing + `.bak` state is never destroyed by a FAILED write (V2-bak-survives-failed-write), only by the next successful one (by design).
- Windows semantics reasoned only: `Link`/symlink creation needs privilege there; the codes above are right; `MoveFileEx` with REPLACE_EXISTING already replaces on Windows when the file is not locked, so the fallback only matters for locked/AV-held files, where the move-aside will usually fail as well (then the first error is thrown with the old file intact - good).

## 5. Remaining findings (ranked)
| # | Sev | Finding | Suggested fix |
|---|---|---|---|
| R2-F1 | HIGH | `atomicReplace` deletes `<target>.bak` unconditionally (stale-bak removal and post-commit removal), clobbering a user's `<name>.bak` in the download directory when `FileReceiver` finishes `<name>`. Tests: `V2-receiver-user-bak`, `V2-receiver-user-bak-windows` (red). | In `atomicReplace` delete a backup ONLY if this very call created it (local `movedAside` flag, delete it after the commit; no stale-bak deletion there). Do the stale-bak rules (remove a stale bak when the target exists; remove a bak after a successful store write) in `_write`/`atomicWriteBytes` only, whose directories are app-owned. Alternatively give `atomicReplace` a `{String? backupSuffix}` and let the receiver use a random one. Both V2 FINDING tests must go green; the other tests must stay green. |
| R2-F2 | MEDIUM | `recoverAtomicBackup` is not wired into `load()` of the stores, so the fixed `.bak` is still stranded and then silently deleted by the next successful write (Windows-reachable only). | Wire it (or call it at the start of `atomicWriteBytes` under the queue, before the stale-tmp handling) so a missing target with a `.bak` is restored first. Test to add with the wiring: crash simulation P3b, then a fresh `atomicWriteBytes` reading the old value first. |
| R2-F3 | LOW | Negative filter keeps the needless move-aside for EROFS/EDQUOT/EIO/unknown errno on POSIX. | On POSIX skip the fallback altogether except when the hook seam is set, or switch to a positive list (Windows 5, 32, 183). The tester's hooks use errno 5, so keep 5 working under the seam. |
| R2-F4 | LOW | Mutant k is not caught by any tester test (all Windows-like hooks carry errno 5). | Adopt V2-F1-noerrno. |
| R2-F5 | LOW | `recoverAtomicBackup` unqueued; `throw first` drops the stack; queue key not canonical for symlinked dirs / Windows case. | See section 4. |
| R2-F6 | INFO | 12 mutants survive the tester's tests (c, e, g, i2, j, k, l, n, o, p, q, r). | Adopt the verifier mutation and V2 tests. |

Round-1 findings: F1 fixed (EXDEV/ENOSPC no longer move the target; V2-F1-18/-28), F2 fixed in code (fixed `.bak`, recovery helper; wiring open = R2-F2), F3 fixed (P2a/P2b/dangling), F4 fixed (P4b, V2-queue-key-dotdot), F6 fixed (V2-first-error x2). Real-tree CLI baseline red from round 1 is now green (`+77`).

## 6. Files
`docs/plans/e-proposals/r1b/verifier-tests/`: `atomic_file_verifier_probes_test.dart` (20 tests, all green; P2a/P3a/P3b updated), `atomic_file_verifier_mutation_test.dart` (5, green), `atomic_file_verifier_v2_test.dart` (20; 2 intentionally red until R2-F1 is fixed), `mutation-results.txt`. All three are verifier tests (not tester, not coder). Logs: `.toolchain/tmp/verif2_*.log`; scripts `.toolchain/tmp/verif2_*.sh`.
