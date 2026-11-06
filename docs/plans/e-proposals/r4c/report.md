# R4c report (coder, 2026-11-06)
Change: `packages/libreshare_core/lib/src/engine/libreshare_engine.dart` only: `_greetContacts` now calls new `_greet(fp, attempt)`; a failed `POST /register` (registrar false/throws) is retried with back-off; per-contact `Timer`s in `_greetRetry`, all cancelled in `stop()`. Retry stops when the contact is removed/no longer listed, the engine stops, or visibility is no longer Contacts-only. Only contacts are greeted. No protocol/contract change.
Back-off: 8 x 0.5 s, 2 x 1 s, 2 x 2 s, 2 x 5 s, 2 x 10 s = 16 retries, about 40 s total (covers >= 3.5 s as required).

## Commands (clone, real rc)
- single file, 3 runs under flock: each `+5 -1` (5 pass; red = `regreet-after-restart` only); finished 12:16:32, 12:19:33, 12:22:05 (the printed rc=1 is the test rc). Before the change: +3 -3 (tests-plan).
- `dart test -j 1` packages/libreshare_core: rc=1 at 12:29:27, 2596 passed, 1 skipped, 1 failed = exactly `regreet-after-restart`. (Count is below the ">= 2607" estimate; the baseline of the clone was not re-measured, so the difference is unexplained but no other test fails.)
- `dart test -j 1` packages/libreshare_cli: rc=0 at 12:37:11.
- `dart analyze --fatal-infos packages/libreshare_core`: rc=0. `dart format --output=none --set-exit-if-changed` on the engine file: rc=0.

## Deferred (by orchestrator, Q4): `regreet-after-restart` is red by design
Re-greeting an already-listed same-fingerprint announce is forbidden by LSP-1 4.2 rule 2. Not implemented, test not touched. `regreet-rate-limited` and the other 4 are green.

## Risks
- Up to 16 extra POSTs per contact per episode, only toward listed contacts; ~40 s window, then a documented limit.
- Contact re-listed after removal: `_greeted` is cleared on removal, so a new greeting cycle starts.
