# LibreShare Execution Plan (run-plan.md)

Generated: 2026-11-05
Based on `docs/plans/MASTER_PROMPT.md` and `docs/plans/HANDOFF.md`.

## Schedule and Wave Structure

### Wave 1: Read-only Audits (Concurrency: 3, Independent)
| Card | Title | Role | Allowed Edits (Exclusive) | Gate | Status |
|---|---|---|---|---|---|
| A1 | Baseline measurement | Auditor | `docs/test-reports/baseline-2026-11-05.md` | None | DONE |
| A3 | Security hygiene sweep | Auditor | `docs/test-reports/inc3-hygiene-sweep.md` | None | DONE |
| A9 | Windows readiness audit | Auditor | `docs/test-reports/windows-readiness.md` | None | DONE |

### Wave 2: Documentation and Static Reviews (Concurrency: max 3)
| Card | Title | Role | Allowed Edits (Exclusive) | Gate | Status |
|---|---|---|---|---|---|
| A4 | README refresh | Docs / Auditor | `README.md` | None | DONE |
| A5 | Demo guide (draft) | Docs / Auditor | `docs/dev/demo-mvp.md` | None | DONE |
| A6 | Traceability update for Inc 3 | Docs / Auditor | `docs/traceability.md` | None | DONE |
| A7 | Install-script review | Auditor | `docs/test-reports/install-scripts-review.md` | None | DONE |
| A8 | CI workflow proposal | Auditor | `docs/plans/ci-proposal.md` | None | DONE |
| A10 | Licence and dependency audit | Auditor | `docs/dev/licences.md` | None | DONE |

### Wave 3: Flake Hunt
| Card | Title | Role | Allowed Edits (Exclusive) | Gate | Status |
|---|---|---|---|---|---|
| A2 | Flake hunt for Inc 3 test files | Tester / Auditor | `docs/test-reports/inc3-flake-log.md` | `P6A_GATE: DONE` | DONE |

### Wave C: P6a / F3 Follow-ups (added 2026-11-05 evening)
| Card | Title | Subagents | Allowed Edits | Gate | Status |
|---|---|---|---|---|---|
| C1 | `FileReceiver.getSession` follows LSP-1 §4.3 | Coder, Verifier | `packages/libreshare_core/lib/src/transfer/file_receiver.dart` (line ~624 getSession condition only) | `WAVE_C_READY: YES` | VERIFIED |
| C2 | Remove engine workaround & CLI import hack | Coder, Verifier | `packages/libreshare_core/lib/src/engine/libreshare_engine.dart`, `packages/libreshare_cli/lib/ls_cli.dart` | C1 verified | DONE |
| C3 | `PeerRegistry.seen` keeps manual/QR address | Coder, Verifier | `packages/libreshare_core/lib/src/discovery/peer_registry.dart` | F3 coder done | DONE |
| C4 | Full P6a gate | Verifier | Read-only gate run | C1+C2+C3 done | DONE |

### Wave B: Implementation and Packaging (Sequential per Card: Tester -> Coder -> Verifier)
| Card | Title | Subagents | Allowed Edits | Gate | Status |
|---|---|---|---|---|---|
| B1 | MVP-App security screens | Tester, Coder, Verifier | `apps/libreshare_app/lib/**`, new widget tests in `apps/libreshare_app/test/**` | `P6A_GATE: DONE` | DONE (screens built) |
| B2 | F3 Android/app usability fixes | Tester, Coder, Verifier | `apps/libreshare_app/lib/**`, `apps/libreshare_app/android/**`, new tests | `F3_TESTS_READY: YES` | DONE |
| B3 | Rebuild, repackage, emulator re-test | Packaging Agent | `dist/prototype/**`, `docs/dev/testing-prototype.md`, `docs/dev/demo-mvp.md` | `MVP_APP_DONE: YES` | STOPPED (superseded by D5) |
| B4 | MVP acceptance checklist | Acceptance Verifier | `docs/test-reports/mvp-acceptance.md` | B1, B2, B3 done | CLOSED by orchestrator |

### Wave D: Secure Engine Wiring & MVP Production Readiness
| Card | Title | Subagents | Allowed Edits | Gate | Status |
|---|---|---|---|---|---|
| D1 | Wire app to secure engine & real PIN | Tester, Coder, Verifier | `apps/libreshare_app/lib/**`, `apps/libreshare_app/test/d1_*_test.dart` | `B_MODULE_DONE: YES` | READY (Spawning Tester) |
| D2 | Hygiene left by Wave B/C & log fix | Lead | `docs/plans/handoff-log.md` | None | DONE |
| D3 | P6a adversarial review (C5) | Verifier | `/tmp/lead-scratch/clone/`, `docs/test-reports/p6a-adversarial-review.md` | After C1+C2 | QUEUED |
| D4 | Android file opener path hardening | Coder, Verifier | `apps/libreshare_app/android/app/src/main/kotlin/dev/libreshare/libreshare_app/FileOpenerChannel.kt` | None | QUEUED |
| D5 | Re-package after D1 & emulator check | Packaging Agent | `dist/prototype/**`, `docs/dev/testing-prototype.md`, `docs/dev/demo-mvp.md` | `APP_SECURE_WIRED: YES` | WAITING |

## Invariant Reminders
1. Concurrency limit: at most 7 subagents running simultaneously (updated 2026-11-06 per user authorization).
2. Exclusive file ownership enforced per subagent.
3. Exit codes must be captured and verified (`cmd > /tmp/x.txt 2>&1; echo rc=$?`).
4. Never commit, push, or run external network/package installs.
5. Never delete scratch, temp, or dead files unless explicitly asked by the user.
6. ONE heavy test suite at a time (`flock -o /tmp/libreshare-heavy.lock <cmd>`). Run `adb kill-server` and `gradle --stop` after Android/emulator operations.
