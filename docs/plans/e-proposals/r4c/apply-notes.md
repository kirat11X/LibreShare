# R4c apply notes
Apply `patch.diff` (paths relative to repo root, `patch -p1`) to `packages/libreshare_core/lib/src/engine/libreshare_engine.dart`; add the test file `packages/libreshare_core/test/integration/contacts_greeting_retry_test.dart` from the clone.
Do NOT apply the test file to the real suite as-is: `regreet-after-restart` is deferred by the orchestrator (Q4) and stays red by design; the orchestrator decides how to carry it (the suite would otherwise fail). The other 5 tests pass. Re-run core and cli suites after applying.

## Orchestrator decision on the deferred red test (2026-11-06 12:38:16 by `date`)
The coder's counts (core 2596 passed + 1 failed, CLI 75) are the CLONE baseline (2591 / 75) plus the new tests; the real tree is at 2607 / 77. Explained, not a regression.
When the patch is applied, `regreet-after-restart` goes into the real suite as a documented skip: the R4 tester (not a coder) adds `skip: 'DEFERRED (questions.md Q4): LSP-1 4.2 rule 2 forbids a reply to an already-listed same-fingerprint announce; known limit'` to that one test and nothing else, so the file stays honest (1 more skipped test, listed in the acceptance report) instead of a permanently red suite. The test body is not edited or weakened. If the user later wants re-greeting after a restart, the LSP-1 amendment in Q4 comes first and the skip is removed in the same change.
