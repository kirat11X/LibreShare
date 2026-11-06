# R1b tests-plan (tester, 2026-11-06)

Clone: `.toolchain/scratch/e5-r1b/clone`. All files NEW (no lib file, no existing test touched):
- `packages/libreshare_core/test/helpers/atomic_hooks.dart` (rename hooks: `recordingRename`, `windowsLikeRename`, `failingRename`, `lockedFileRename`, `RenameLog`)
- `packages/libreshare_core/test/unit/atomic_file_test.dart` (20 tests, helper semantics)
- `packages/libreshare_core/test/unit/atomic_file_adoption_test.dart` (12 tests: resume_store, receive_settings_store, file_secret_store, FileReceiver final move)

## API the coder must implement: `packages/libreshare_core/lib/src/storage/atomic_file.dart`
```dart
typedef AtomicRenameFn = Future<void> Function(File from, String toPath);
AtomicRenameFn? atomicRenameOverride;   // test seam; null = real File.rename. EVERY rename the helper does (commit, move-old-aside, restore) goes through it.
Future<void> atomicWriteBytes(File target, List<int> bytes,
    {int? mode /* POSIX, 0x180 = 0o600, applied to the tmp before any byte; ignored on Windows */,
     Future<void> Function(File tmp)? prepareTmp /* runs on the still-empty tmp */});
Future<void> atomicReplace(File tmp, File target);   // tmp must exist, else FileSystemException and target untouched
```
Contract: new bytes or exactly the OLD bytes; on any failure no tmp/backup litter (directory holds only the target); a rename that refuses to replace an existing file (Windows) must still succeed, WITHOUT ever deleting the old file before the new one is committed (use move-aside + restore on failure, the "locked file" test forbids delete-then-rename); concurrent writers to one target are serialised or use unique tmp names (never a shared half-written tmp); a stale `<target>.tmp` from an old crash is overwritten/removed (existing receive_settings test requires `<path>.tmp` to be gone after a save, so keep the `.tmp` name + an in-process per-target queue). The existing `writeFileAtomically` (file_secret_store.dart, also used by credential_store and device_registry) should delegate to the new helper; `FileSecretStore` keeps its `ChmodRunner` fail-closed behaviour (use `prepareTmp`). `app_settings_store.dart` is app code: follow-up, not tested here.

## atomic_file_test.dart (guard = name prefix)
create-when-absent; replace-existing (longer/shorter); empty-payload; stale-tmp-overwritten; goes-through-rename-hook; cleanup-on-rename-failure (target present / absent); never-delete-before-commit (locked old file; atomicReplace with missing tmp; atomicReplace with locked target); real-fs-failure-cleanup (target path is a non-empty directory, no hook); prepareTmp-failure-cleanup (+ tmp empty at prepare); replace-fallback (Windows-like rename, repeated, and atomicReplace); mode-applied (new file, replacing a 0644 file; skipped on Windows: "POSIX permission bits do not exist on Windows"); prepareTmp-sees-empty-tmp; no-torn-reads (8 writers x 5 rounds on one 256 KiB target, a reader polling, every read exactly one payload, no litter).

## atomic_file_adoption_test.dart
resume_store-uses-helper / -replace-fallback / -cleanup; receive_settings-uses-helper / -replace-fallback / -cleanup; secret_store-uses-helper / -replace-fallback+0600 / -0600-through-helper / -cleanup (0600 on files, 0700 dir, Linux only); receiver-final-move-uses-helper / -windows. The "uses-helper" tests fail if a store keeps calling `File.rename` itself (mutation target); "-cleanup" tests (rename hook fails) fail unless the store commits through the helper and the helper cleans up.
Note: the "-replace-fallback" adoption tests pass even without adoption (the hook is simply not consulted); they only bite after the stores use the helper and the fallback is removed (mutation: delete the fallback).

## Commands (cwd `clone/packages/libreshare_core`, `flock -o /tmp/libreshare-heavy.lock dart test -j 1 <file>`)
RED (real state of the clone): both files fail to load, `Error when reading 'lib/src/storage/atomic_file.dart': No such file or directory`, **rc=1** each (2026-11-06 10:33:33). This is the unavoidable red of a new API.

Evidence that the tests are satisfiable and red for the right reasons (tester-only throwaway copy `.toolchain/scratch/e5-r1b/stubcheck`, NOT a deliverable):
- a reference `atomic_file.dart` (move-aside fallback, per-target queue): `atomic_file_test.dart` 3 runs, each `+20: All tests passed!` rc=0 (10:33:22); adoption file with the stores untouched: 8 red (the 4 "uses-helper" and the 3 "-cleanup" tests plus secret_store-0600-through-helper), 4 green, rc=1.
- a naive helper (shared `.tmp`, no fallback, no cleanup, no mode): 11 of 20 red (cleanup x2, locked, real-fs, prepareTmp, both Windows-like, both mode tests, mode-sees-empty, no-torn-reads).

## Lint-only fix of atomic_file_adoption_test.dart (tester, 2026-11-06, orchestrator request)
Change: removed the 6 unnecessary `package:libreshare_core/src/...` imports (clock, file_item, session_models, file_secret_store, file_receiver, resume_store; all symbols come from the barrel) and turned `final partial = () => ...` into `File partial() => ...`. No assertion, name, count or behaviour changed (still 12 tests). Clone: `.toolchain/scratch/e5-r1b/clone`; coder's lib untouched.
- `dart analyze --fatal-infos` (cwd packages/libreshare_core, under the heavy lock): started 12:17:13, "No issues found!", **rc=0** (no infos in any other file). Before the fix: 7 infos, all in this file (12:15:20).
- `dart format --output=none --set-exit-if-changed test/unit/atomic_file_adoption_test.dart`: `Formatted 1 file (0 changed)`, **rc=0**.
- `dart test -j 1 test/unit/atomic_file_test.dart test/unit/atomic_file_adoption_test.dart`: started 12:19:44, finished 12:22:10, `+32: All tests passed!`, **rc=0**.
- Fixed file copied to `docs/plans/e-proposals/r1b/atomic_file_adoption_test.dart` (`cmp` rc=0 against the clone).
