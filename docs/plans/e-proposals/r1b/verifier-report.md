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

---

# Round 3 (verifier, 2026-11-06 20:59-21:17 by `date`)

Subject: the regenerated `patch.diff` (20:46) of the R2-F1 fix. Fresh clone of the current real tree: `.toolchain/scratch/e5-r1b-verify3/clone`. Real tree and tester files untouched.

## Verdict: SAFE AFTER FIXES - the code is SAFE, the DELIVERED `patch.diff` is UNSAFE (one blocking finding, R3-F1)

### R3-F1 (BLOCKER, delivery): `patch.diff` is polluted with unrelated reverse changes
The regenerated `patch.diff` has 21 file sections (136 KB) instead of 5. It was made with `diff -ruN` between the CURRENT real tree and the coder's OLDER clone, so every file in which the real tree moved on appears as a change to be undone. Measured in a copy of the current real tree:
- `patch -p1 --dry-run < patch.diff` rc=0 and `patch -p1 < patch.diff` rc=0 (no warning!), after which `packages/libreshare_core/lib/src/connection/` and `.../monitor/` DO NOT EXIST any more (`ls` rc=2 for both).
- It deletes or rewrites: `libreshare_core.dart` (drops 11 barrel exports), `connection/{candidate,connection,connection_manager,http_connection}.dart`, `monitor/{channel_event,event_log,event_record}.dart`, `storage/{session_record,session_store}.dart`, `transfer/{idle_timeout_manager,receiver_adoption_helper}.dart`, `engine/libreshare_engine.dart`, `model/events.dart`, `transfer/{file_sender,hashing}.dart`; and inside `file_receiver.dart` it also removes the running-hash optimisation (`runningHasher`, `nextExpectedChunkIndex`, ... 6 hunks) next to the 3 real R1b hunks.
Applying it would silently destroy increments 4 and 5 of the real tree. NOT to be applied.
Fix: regenerate against the current real tree restricted to the 5 R1b files, and in `file_receiver.dart` keep only the 3 R1b hunks (import + two `atomicReplace` lines). I produced exactly that as `docs/plans/e-proposals/r1b/verifier-patch-r1b-only.diff` (5 sections, 326 lines): `patch -p1 --dry-run` rc=0, `patch -p1` rc=0 on the fresh clone, and `diff -rq` of the clone's `lib/` against the real tree lists exactly the 5 R1b files (+ new `atomic_file.dart`); the `file_receiver.dart` delta is exactly 3 lines. All results below are for this clean patch (the lib content of `atomic_file.dart`, `file_secret_store`, `receive_settings_store`, `resume_store` is identical to the coder's sections of `patch.diff`, extracted by header). The orchestrator may use my file or regenerate; either way check `grep -c '^--- ' patch.diff` = 5 and `patch --dry-run` on the real tree.

### Gates (clone = real tree + clean patch; every run under `flock -o /tmp/libreshare-heavy.lock`, TMPDIR=.toolchain/tmp)
| Gate | Result | rc |
|---|---|---|
| clean patch apply | 5 files | 0 |
| `atomic_file_verifier_v3_test.dart` (new, 15 tests, 21:11:47) | `+15 All tests passed` | 0 |
| five+v3 files (tester 2 = 32, probes 20, mutation 5, v2 20, v3 15) x3 (21:11:48-21:12:03) | `+92 All tests passed` x3 | 0, 0, 0 |
| `dart analyze --fatal-infos` clone root (incl. all test files) | No issues found | 0 |
| `dart format --output=none --set-exit-if-changed` on the 5 lib files + 6 atomic test files + hooks | 12 files, 0 changed | 0 |
Full suites skipped as instructed. Confirmed GREEN now (coder's claim correct): P2a, P3a, P3b, `V2-receiver-user-bak`, `V2-receiver-user-bak-windows`, and all 4 former FINDING tests; the whole v2 file is green (20/20).
(One earlier five-file run, +77 at 21:07, was made while my clone temporarily held the polluted file_receiver and is NOT counted.)

### Mutation table (copy `mut/`, one at a time, restored, `diff -r` clone vs mut rc=0 in all 29 runs, no "MUTATION NOT APPLIED"; raw `verifier-tests/mutation-results-round3.txt`; baseline +92 all green)
Reds = tests newly red out of the 92 (tester files / verifier files).
| # | Mutation | Reds | Killed by |
|---|---|---|---|
| a | no move-aside fallback | 24 | tester 6 + many |
| b | delete the old target first | 18 | tester 6 (never-delete, cleanup) + ours |
| c | no restore after failed commit | 3 | V-restore x2, V2-first-error (tester: 0) |
| d | tmp not removed on failure | 18 | tester 8 + ours |
| e | stale tmp not removed | 1 | V-stale-tmp-readonly (tester: 0) |
| f | no per-target queue | 4 | tester no-torn-reads + P4 + V2-queue-key |
| g | mode after bytes | 2 | V-mode-before-bytes, P6 (tester: 0) |
| h1 | own `.lsbak` backup NOT deleted after commit | 18 | tester 6 + ours incl. V3-user-bak/backup-name |
| h2 | fixed `.bak` not removed after plain commit (store path) | 1 | V2-bak-removed-after-plain-success (tester: 0) |
| i / i2 | receiver renames back to plain `rename` | 4 / 1 | adoption uses-helper / V-receiver-copy-fallback (i2: tester 0) |
| j | errno filter removed | 6 | P1b, V2-F1-18/-28, V3-errno-30/-122, V3-other-filesystem (tester: 0) |
| k | errors without osError skip the fallback | 1 | V2-F1-noerrno only (tester: 0) |
| l | stale-bak removal (store path) skipped | 1 | V2-stale-bak-removed (tester: 0) |
| n | symlink-at-tmp deletion removed | 3 | P2a, P2b, V2-dangling-symlink |
| o | queue key not normalised | 2 | P4b, V2-queue-key-dotdot |
| p | recover restores although target exists | 1 | V2-recover-keeps-existing-target |
| q / r | `rethrow` instead of the FIRST error (move-aside / commit path) | 1 / 2 | V2-first-error-moveaside / V2-first-error, V3-double-failure |
| **s** | atomicReplace backup is the fixed `<t>.bak` again (user file clobbered) | 4 | V3-user-bak-windows, V3-backup-name, V3-double-failure, V3-crash-window (V2-receiver-user-bak* stay green because the plain rename needs no backup; tester: 0) |
| **t** | atomicReplace deletes `<t>.bak` after commit again (the R2-F1 bug) | 3 | V2-receiver-user-bak, -windows, V3-user-bak-plain (tester: 0) |
| **u** | atomicReplace uses `fixedBak: true` | 7 | V2 x2, V3 x5 |
| **v** | atomicWriteBytes uses `fixedBak: false` (store path loses `.bak` rules) | 7 | probes x2, V2 x4, V3-fixed-in-write |
| **w** | unique-name free-check removed | 0 | SURVIVES: equivalent mutant in practice (a 32-bit random collision with an existing entry; cannot be provoked without a seam for the RNG) |
| **x / y / z** | errno 30 / 122 / 28 dropped from the no-fallback list | 1 / 1 / 1 | V3-errno-30 / V3-errno-122 / V2-F1-28 |
| **aa** | EIO(5) added to the no-fallback list | 22 | tester 6 (Windows-like simulations) + ours |
The only survivor is w (equivalent). Survivors of the TESTER's two files alone: c, e, g, h2, i2, j, k, l, n, o, p, q, r, s, t, u, v, x, y, z - all covered by the verifier files, so the verifier files must travel with the patch.

### Attempts to break the new code (all in `atomic_file_verifier_v3_test.dart`, 15 tests green)
- **User files untouched** (the R2-F1 scenario): user `<t>.bak` survives a Windows-like replace and a plain replace; a user `<t>.lsbak-deadbeef` survives too; during the window the old bytes are in exactly one `<t>.lsbak-<hex>` (never `.bak`), gone after the commit.
- **Crash between move-aside and commit** (rename hangs forever): target absent, old bytes in exactly one `.lsbak-<hex>`, new bytes in `.tmp`; `recoverAtomicBackup` returns false (it only knows the fixed `.bak`). Same for a double failure (old bytes in one `.lsbak-<hex>`, error = the FIRST). Consequence: on the receiver path a crash in the window leaves a recoverable-by-hand `lsbak` file nobody looks for (LOW; in practice the receiver only reaches the move-aside in a race, since it picks a free name for an existing target).
- **Backup name collision**: the free-check is the only guard (mutant w): a name taken after the check would be overwritten only on a filesystem that allows rename-over, i.e. never in the situation where the fallback runs (Windows refuses). Not exploitable.
- **Real other filesystem** (`/dev/shm` -> temp dir, different devices): `atomicReplace` throws errno 18 after exactly ONE rename attempt, target never missing, old bytes intact, tmp intact.
- **Symlink target**: `atomicWriteBytes` replaces the link with a regular file, the linked file is untouched (same as the pre-patch rename); with a Windows-like refusal a link is not a regular file, so no move-aside happens: error, link and real file intact.
- **Read-only directory**: `atomicWriteBytes` throws `FileSystemException`, old target intact, no litter; `atomicReplace` with tmp+target present throws, BOTH files intact, no backup.
- **Concurrent replace of one target** (6 unqueued `atomicReplace`, Windows-like refusal): 1 succeeds, 5 throw `FileSystemException` (they see the target momentarily moved aside and refuse), the target is always one whole payload, no backup litter, the failed callers' tmp files keep their bytes. No corruption; only the receiver uses this path and it never targets one name twice. (Writers via `atomicWriteBytes` are queued: no-torn-reads test.)
- Errno list verified: 18, 28, 30, 122 -> exactly one rename, never a missing target; 5 and 13 still fall back (the tester's simulations rely on 5).

### Remaining findings
| # | Sev | Finding | Suggested fix |
|---|---|---|---|
| R3-F1 | BLOCKER | `patch.diff` reverts increments 4/5 (see above). | Replace with `verifier-patch-r1b-only.diff` or regenerate (5 sections, `file_receiver.dart` 3 hunks), re-run `patch --dry-run` on the real tree at apply time. |
| R2-F2 | MEDIUM, known limit (Windows only) | `recoverAtomicBackup` not wired into the stores; the fixed `.bak` can be stranded and is removed by the next successful write; the receiver-path `.lsbak-<hex>` is not recoverable by it at all. | Wire it in a follow-up (store `load()` / start of `atomicWriteBytes` under the queue); documented in apply-notes. |
| R3-F2 | LOW | Unqueued concurrent `atomicReplace` of one target fails 5 of 6 (safe, no data loss). | None needed for the receiver; document. |
| R3-F3 | LOW | `throw first` loses the original stack trace; queue key not canonical for symlinked dirs / Windows case; POSIX negative list still lets unknown errnos run the move-aside. | Optional. |

### Which test files must be applied with the patch
Into `packages/libreshare_core/test/unit/`: `atomic_file_test.dart`, `atomic_file_adoption_test.dart` (tester), and ALL FOUR verifier files from `docs/plans/e-proposals/r1b/verifier-tests/`: `atomic_file_verifier_probes_test.dart` (20), `atomic_file_verifier_mutation_test.dart` (5), `atomic_file_verifier_v2_test.dart` (20), `atomic_file_verifier_v3_test.dart` (15); into `test/helpers/`: `atomic_hooks.dart`. Together +92, all green with the clean patch. The verifier files are verifier-written (not tester/coder). `mutation-results-round3.txt` is evidence only.
