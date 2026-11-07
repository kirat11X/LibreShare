# R1b apply notes (coder, 2026-11-06)
- Apply from the repo root: `patch -p1 < docs/plans/e-proposals/r1b/patch.diff` (dry-run against a copy of the real lib/: rc in report.md). Then copy the three test files into packages/libreshare_core/test/{unit,helpers}/ (atomic_file_test.dart, atomic_file_adoption_test.dart -> test/unit; atomic_hooks.dart -> test/helpers).
- Conflict with R1a: none expected. R1a edits file_receiver.dart near lines ~702/713 and ~1312 (FileMode.append); R1b touches only the import block and the final move (~line 909-920). Different hunks.
- Conflict with R1cd: none expected (no overlapping files known to the coder).
- Barrel: atomic_file.dart is NOT exported (orchestrator-owned); it is imported by src path only. The app needs it only for the follow-up below.
- Follow-up (not done, app file): apps/libreshare_app/lib/services/app_settings_store.dart should write via atomicWriteBytes; that needs `atomic_file.dart` exported from the core barrel (or a `package:libreshare_core/src/...` import) - orchestrator decision.
- credential_store and device_registry call writeFileAtomically (now delegating), so they gain the helper automatically.
- The clone is an older snapshot of the tree: it lacks test/security/mitm_test.dart, test/helpers/faulty_tcp_proxy*.dart and cli/test/loopback_smoke_secure_test.dart, hence 2623 core / 75 cli instead of the real-tree baselines. Re-run the real-tree gate after applying.

## Round 2 (verifier fixes)
- Apply with the patch: tester files (atomic_file_test, atomic_file_adoption_test, atomic_hooks) and verifier-tests/atomic_file_verifier_mutation_test.dart (5 tests, green).
- verifier-tests/atomic_file_verifier_probes_test.dart: its 4 FINDING tests are green, but P2a, P3a, P3b are red because they pin the old behaviour (symlink write-through, `.bak-<hex>` name). Apply it ONLY after those three are updated by their owner; until then leave it out.
- Follow-up: wire `recoverAtomicBackup(target)` into the stores' startup/load (credential_store, device_registry, file_secret_store, receive_settings, resume sidecar) and app_settings_store; not in this patch.

## Round 3
- Apply with the patch: the 3 tester files and all three verifier files (atomic_file_verifier_probes_test, _mutation_test, _v2_test) into test/unit/ (atomic_hooks.dart into test/helpers/); all green (+77 on the five atomic files).
- Known limit / follow-up (R2-F2, Windows only): recoverAtomicBackup is not wired into the stores' startup.
