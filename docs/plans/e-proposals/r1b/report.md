# R1b coder report (2026-11-06)
Clone: .toolchain/scratch/e5-r1b/clone. No test or helper edited. Real tree untouched.

## Files touched (lib/ only)
NEW storage/atomic_file.dart (atomicWriteBytes, atomicReplace, AtomicRenameFn, atomicRenameOverride; `<path>.tmp` + in-process per-target queue; chmod before any byte for `mode`; stale tmp removed; Windows-style refusal -> move old aside to `<target>.bak-<hex>`, rename in, restore on failure, never delete first; tmp removed on any failure in atomicWriteBytes).
CHANGED storage/file_secret_store.dart (writeFileAtomically delegates; ChmodRunner fail-closed via prepareTmp kept), storage/receive_settings_store.dart, transfer/resume_store.dart (both use atomicWriteBytes), transfer/file_receiver.dart (import + both final renames -> atomicReplace).

## Commands (cwd clone/packages/..., TMPDIR=.toolchain/tmp, tools/env.sh, flock -o /tmp/libreshare-heavy.lock)
- Red (before code): see tests-plan.md (load error, rc=1).
- `dart test -j 1 test/unit/atomic_file_test.dart test/unit/atomic_file_adoption_test.dart` x3 (12:07+): +32 All tests passed, rc=0, 0, 0.
- core `dart test -j 1`: rc=0, +2623 ~1 (12:09:45-12:12).
- cli `dart test -j 1`: rc=0, +75.
- core `dart analyze --fatal-infos`: rc=1, 7 infos, ALL in test/unit/atomic_file_adoption_test.dart (unnecessary_import x5, prefer_function_declarations_over_variables x1 + 1); 0 issues in lib/. Tester-owned file, not edited: tester must fix.
- `dart format --output=none --set-exit-if-changed` on the 5 lib files: rc=0 (0 changed).
- patch dry-run: see apply check below.

## Surprises
- Counts below the stated floors (2607+32, 77): the clone is an older snapshot lacking mitm_test.dart, faulty_tcp_proxy*.dart (core) and loopback_smoke_secure_test.dart (cli) that exist in the real tree (`diff -rq`). New tests all pass; floors must be re-checked in the real tree.
- Analyze rc=1 is caused only by the tester's test file.
- patch -p1 --dry-run against a throwaway copy of the real lib/: rc=0 (all 5 files).

## Round 2: verifier fixes (2026-11-06 14:03-14:20), lib/storage/atomic_file.dart only
- F1: move-aside is skipped (original error rethrown) for OSError EXDEV 18 / ENOSPC 28 on POSIX and 17 / 112 / 39 on Windows; any other error (incl. no osError) keeps the fallback. Probe FINDING P1b green.
- F2: fixed `<target>.bak`. Stale bak + existing target: bak removed before move-aside. Target missing + bak: bak untouched until the new target is committed, then removed (also removed after a plain successful rename). New public `recoverAtomicBackup(File)` (restores only if target missing; not wired into the stores). FINDING P3c green. Double failure (2nd rename and restore both fail): old data stays in `<target>.bak`, target absent, tmp removed; the next successful write or recoverAtomicBackup deals with it.
- F3: symlink at `<target>.tmp` is deleted (Link.delete) before writing; a directory there still fails safely. FINDING P2b green.
- F4: queue key `p.normalize(p.absolute(path))`. FINDING P4b green.
- F6: failure paths now rethrow the FIRST rename error (not the second).
- F5: the 5 mutation tests are green and are to be applied (see apply-notes.md).
- Commands (clone core, flock -o /tmp/libreshare-heavy.lock):
  - 14:03:23 `dart test -j 1` on the 4 files (2 tester + 2 verifier): rc=1, +54 -3 ; the 3 reds are verifier tests P2a, P3a, P3b (see below); tester files +32 green; mutation file 5/5 green; FINDING P1b/P2b/P3c/P4b green.
  - 14:08:44 core `dart test -j 1`: rc=1, +2634 ~1 -3 (same three reds only).
  - cli `dart test -j 1`: rc=0, +75 (clone baseline; clone lacks loopback_smoke_secure_test).
  - `dart analyze --fatal-infos` (core): rc=0, 0 issues. `dart format --output=none --set-exit-if-changed lib/src/storage/atomic_file.dart`: rc=0.
  - patch.diff regenerated; `patch -p1 --dry-run` on a throwaway copy of real lib/: applies (5 files).
- The 3 red verifier tests are OBSOLETE by design, not code bugs (I may not edit tests): P2a asserts the OLD write-through-symlink behaviour (contradicts F3/P2b); P3a and P3b look for the random name `.bak-<hex>` (contradicts F2's fixed `.bak`). The tester/verifier must update them (P2a: expect other file untouched; P3a/P3b: expect exactly one `state.json.bak` holding the old bytes).

## Round 3: R2-F1 fix (HIGH: atomicReplace deleted a user's `<name>.bak`), 2026-11-06
- atomicReplace (receiver, user-visible dirs) now never reads/deletes/overwrites a file it did not create: move-aside backup is `<target>.lsbak-<hex>` (free name checked with typeSync, retried), and only that backup is deleted after a successful commit. No stale-bak logic there.
- Fixed `<target>.bak` + stale-bak rules + `recoverAtomicBackup` apply only to atomicWriteBytes (shared internal `_replace(..., fixedBak:)`); public signatures unchanged.
- No-fallback errno list (POSIX) now EXDEV 18, ENOSPC 28, EROFS 30, EDQUOT 122 (not EIO 5); Windows 17/112/39.
- Known limit (R2-F2, Windows only): recoverAtomicBackup is not wired into the stores; after a double failure/crash the old data sits in `<target>.bak` until a later write or a manual recover.
- Runs (clone, flock -o /tmp/libreshare-heavy.lock): 15:17:01 the 5 files (tester 2 + verifier probes, mutation, v2) `dart test -j 1`: rc=0, +77 (32+25+20). Core `dart test -j 1`: rc=0, +2668 ~1 (ended 15:46:29). `dart analyze --fatal-infos`: rc=0. `dart format --output=none --set-exit-if-changed atomic_file.dart`: rc=0. CLI `dart test -j 1`: rc=0, +75 (ended 15:52:19). patch.diff regenerated; `patch -p1 --dry-run` on a copy of real lib/: rc=0.
- Note: the earlier obsolete reds (P2a, P3a, P3b) are green in this run, i.e. the verifier files were updated.
