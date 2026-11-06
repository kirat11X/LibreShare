# Increment 3 closure plan (everything still needed to declare Increment 3 DONE)

Written by the orchestrator, 2026-11-06 (real clock at writing: ~03:26). Sources: `docs/plans/inc3.md` (sections 4.1, 5, 6, 7, 9, 9b, 12), `docs/plans/STATUS.md`, `docs/test-reports/mvp-acceptance.md`, `docs/plans/post-mvp-plan.md`, `docs/test-reports/d1-security-review.md`, `docs/test-reports/d1-second-tester.md`, `docs/test-reports/p6a-adversarial-review.md`. Effort numbers are ESTIMATES. "Measured" = a command and its exit code from a run that was alone.

## 1. Three levels of "done" (so nobody over-claims)

| Level | Meaning | State today |
|---|---|---|
| **MVP-closed** | Inc 3 for the MVP cut (`mvp.md`): P1-P7 + P6a in, app wired to the secure engine, packages rebuilt and smoke-tested | NOT reached: app still plaintext until D1 round 2 + D5 (see STATUS) |
| **Container-complete** (target of this plan) | every Inc 3 item that can be built and verified in this container: P8 complete, P9 built, P10 run, Wave 4 close-out (section 9 block, M1-M10, section 12, traceability) | this plan, Modules D/E/F/G |
| **Fully verified** | plus things that need the user's hardware or a pushed repo: real-phone checklist, Windows build and DPAPI, CI green on GitHub | NOT possible here (standing "no push"); listed in section 6 as open items, like Inc 2's outcome |

## 2. Status of every Inc 3 element (from the repo, not from memory)

| Element (inc3.md section 5) | State | Evidence / gap |
|---|---|---|
| W0 contracts, barrel, pubspec | DONE | `inc3-seams.md` |
| P1 crypto, certs, proof, SAS | DONE, 263 tests | `inc3-spikes.md`; spikes S-A/S-B/S-C |
| P2 secret/credential/device/trust stores | DONE, 215 tests | |
| P3 server + PinGuard | DONE, reviewed, fixed | `inc3-p3-tests.md` |
| P4 receiver, consent, pairing, SAS | DONE, reviewed, fixed | `inc3-p4-tests.md` |
| P5 client/sender | DONE, reviewed, fixed | `inc3-p5-tests.md` |
| P6b discovery (signed bye, pins, Contacts-only) | DONE, reviewed, fixed | `inc3-p6b-tests.md` |
| P7 LSP-1 docs, schemas, 40 vectors | DONE | `inc3-p7-drift.md` |
| **P6a** engine + CLI wiring | gate MEASURED green by me (core +2583 ~1, CLI +75); C1-C4 read by me; **C5 adversarial review: the Lead's report says PASS, 10/10 mutations red + new `p6a_adversarial_test.dart` (report 02:59): NOT yet re-run by me** | `P6A_GATE` stays `API-READY` until I re-run it |
| **P8** app UI | **partial**: B1 screens + B5 Open Contacts (fake-engine tests); **D1 secure wiring + real PIN: round 2 in progress** (2 independent reviews FAIL: S1-S6 etc.); **NOT started:** QR pairing screen + visibility selector, notifications, Windows secure key store | `d1-fixes.md`; Module F cards F1-F5 |
| **P9** Android `ReceiveService` | NOT started (spike package) | Module F card F4 (`inc3.md` section 6) |
| **P10** Docker e2e f-l + `--secure` smoke flag + CI | NOT started; `loopback_smoke.sh` has no `--secure` mode (CLI defaults to TLS; the script passes `--insecure-plaintext` on its setup lines by the Q2 decision) | Module E card E1 + closure card G1 |
| **Wave 4 close-out** | NOT started: section 9 command block never run in full; M1-M10 not mapped to named red tests; `inc3.md` section 12 has `[FILL]` items; traceability/roadmap/CLAUDE.md lines not updated | closure cards G2-G6 |
| Section 9b Docker-install requests | `--advertise-ip` and `--identity-dir` implemented (`ls_cli.dart`); broken-pipe cosmetic item: verify in G2 | |

Last measured counts (me, 2026-11-06 00:13-00:19): core +2583 ~1, CLI +75, app +405, loopback 100 MiB 19.0 MiB/s, emulator smoke 18/18 (plaintext app). **Superseded for the app suite: at 04:34 the real tree gave +384 -38 and hung (STATUS.md correction); the app gate is open until the legacy-test diagnosis and D1 round 2 are done.**

## 3. Work to do, by track (owner prompt in brackets)

**Track A - finish the MVP blockers (orchestrator + Lead).**
- A1 D1 round 2 (tester -> coder -> verifier -> my gate) per `docs/plans/d1-fixes.md` [orchestrator, scratch clone `.toolchain/scratch/d1-round2/`].
- A2 I re-run the C5 claims alone: `p6a_adversarial_test.dart` 3x, the 10 mutations spot-checked, full core + CLI; then flip `P6A_GATE: DONE` [orchestrator].
- A3 D5: repackage Linux + Android, `sha256sum -c`, emulator smoke with the secure app (remove `--insecure-plaintext` from its two CLI calls per `d5-smoke-secure.md`, assert the same 6-digit code on both sides), manual check; flip `PACKAGING_DONE`, `MVP_APP_DONE` [ORCHESTRATOR only, user decision 2026-11-06 03:24: the Lead does not run the package script or the emulator smoke].

**Track B - P8 completion (Module F).** F1 pairing screen + Everyone/Contacts-only/Nobody selector; F2 UX leftovers; F3 notification seam + logic (package request to me); F5 Windows key store logic with fakes (DPAPI binding delivered as text, needs `package:win32` and a Windows run).

**Track C - P9 (Module F card F4).** Dart `ReceiveHost` seam + mocked-channel tests, Kotlin foreground service + manifest, compile check, emulator steps (screen off, deviceidle, service type via `dumpsys`).

**Track D - P10 + CI (Module E card E1 and G1).** Docker steps f-l; `loopback_smoke.sh --secure` mode (G1: a flag that drops `--insecure-plaintext`; rate recorded, not gated); CI stays a proposal (no push).

**Track E - Wave 4 close-out (closure cards G2-G6).**
- **G1 Secure smoke mode.** `tools/loopback_smoke.sh <MiB> <port> --secure`: same script without the `--insecure-plaintext` flags; expect rc=0 and byte-identical; record the MiB/s next to the plaintext 19.0 baseline in `docs/test-reports/inc3-docker.md`. (Existing plain mode must behave exactly as today; no assertion changes.)
- **G2 Section 4.1 checklist audit.** For every row of the `inc3.md` section 4.1 table list each test name and find it in the tree (`grep -rn`); produce `docs/test-reports/inc3-checklist-audit.md`: row | test file | test name found Y/N | green in the last full run. Every N gets a new test file (core: patch-only, frozen areas) or an entry in `questions.md`. Also verify the 9b cosmetic item (`info`/`devices` with closed stdout must not throw `FileSystemException: Broken pipe`).
- **G3 Mutation sweep M1-M10** (section 9). In a scratch clone of the final tree apply each of M1-M10 one at a time; each must turn at least one NAMED test red; restore and `diff -r` rc=0; write `docs/test-reports/inc3-mutations.md` (M-id, file:line, mutation, red test name, rc). A survivor gets a new test file (patch-only for core) and a note.
- **G4 `inc3.md` section 12 fill proposal** (the file is orchestrator-only): `docs/plans/inc3-outcome-proposal.md` with every `[FILL]` item answered with commands, counts, file names (done-and-proven block from G6, bugs found and fixed from the per-package notes, M1-M10 map from G3, the setup-line diff confirmation: compare the real tree against the `pre-flip` snapshots that the orchestrator kept; if the snapshots are missing say so).
- **G5 Docs proposals:** `docs/plans/inc3-traceability-proposal.md` (FR-05/06/16/18 rows, NFR-04 part, new "FR-22 Pairing and contacts"), the roadmap rows to flip, the CLAUDE.md Android gotcha line (design 01 section 6), `docs/dev/licences.md` additions. The orchestrator applies them.
- **G6 Final gate run** (the Lead runs, I re-run): the section 9 block exactly, alone, serialized, results in `docs/test-reports/inc3-final.md`.

## 4. The Inc 3 "container-complete" gate (all by real exit codes, run alone under `flock -o /tmp/libreshare-heavy.lock`)

```bash
source tools/env.sh
dart pub get;                                                       echo "pub=$?"       # 0
dart format --output=none --set-exit-if-changed .;                  echo "format=$?"    # 0
dart analyze --fatal-infos;                                         echo "analyze=$?"   # 0
(cd packages/libreshare_core && dart test -j 1);                    echo "core=$?"      # 0; >= 2583 passed + new, 1 skipped
(cd packages/libreshare_cli  && dart test -j 1);                    echo "cli=$?"       # 0; >= 75
(cd apps/libreshare_app      && flutter test --concurrency=2);      echo "app=$?"       # 0; >= 405 + new
bash tools/loopback_smoke.sh 100 <free port>;                       echo "smoke=$?"     # 0; byte-identical; no regression > 20 % of 19.0 MiB/s
bash tools/loopback_smoke.sh 100 <free port> --secure;              echo "smoke_tls=$?" # 0 (G1); rate recorded, not gated
docker compose -f tools/docker/compose.yaml up --build --abort-on-container-exit --exit-code-from tester; echo "e2e=$?"   # 0, a..e and f..l PASS (E1); then down -v
grep -RnE "package:flutter|dart:ui" packages/libreshare_core/lib;   echo "grep=$?"      # 1
tools/package_prototype.sh linux android;                           echo "package=$?"   # 0 (never wrapped in the flutter-build flock); then sha256sum -c rc=0
tools/android_emulator_smoke.sh;                                    echo "smoke_android=$?"  # 0, secure app, same 6-digit code both sides (D5)
```
plus: every new test file 3x green; M1-M10 each red (G3); the section 4.1 audit has no unexplained N (G2); `P6A_GATE: DONE`, `APP_SECURE_WIRED: YES`, `MVP_APP_DONE: YES`, `PACKAGING_DONE: YES`; the P9 emulator steps and U-card tests green as delivered by Module F; no existing Inc 1/2 test changed except the approved setup lines (diff against `pre-flip`).

## 5. Order and rough effort (estimates, one human; agent-run differs)

| Step | Items | pd (estimate) | Depends on |
|---|---|---|---|
| 1 | A1 D1 round 2, A2 C5 re-run, A3 D5 | 2-3 | in progress |
| 2 | Docs lane (E2, E3, E4) in parallel with 1 | 3 | none |
| 3 | F1, F2 (pairing, UX) | 5 | A1 gated |
| 4 | E1 Docker f-l, G1 secure smoke | 4 | none for E1 (CLI only), G1 none |
| 5 | F3, F5 (notification logic, key-store logic) | 5 | A1 gated |
| 6 | F4 Android service | 6 (confidence low) | A1 gated, emulator |
| 7 | G2 checklist audit, G3 mutation sweep | 4 | steps 1-6 as far as they changed code |
| 8 | G4, G5 proposals, G6 final gate | 2.5 | everything else |
Total about 31 pd (estimate; the original Inc 3 plan said about 27 pd for the whole increment, so this is the remaining part plus the MVP rework that the cut and the reviews added).

## 6. What cannot be closed in this container (stays open, stated in the outcome)

1. **Real Android phone**: screen-off 30 min receive, battery saver, OEM killers, boot opt-in (`docs/test-reports/inc3-android.md` is a blank checklist for the user).
2. **Windows**: nothing has been compiled or run on Windows; DPAPI store, toasts, `\\?\` paths, rename-over-existing: needs a Windows PC or an Actions run (no repo is pushed).
3. **CI**: `ci.yml` has never run (standing "no push").
4. **Camera QR scanning**: logic and the paste path are testable; the camera only on a phone.
5. NFR-02 throughput (about 19-30 MB/s vs the 300 MB/s target) is Increment 4, as the outcome already says.

## 7. Honesty rules for every report in this plan

A step is DONE only with the command and its exit code from a run that was alone; red runs are listed; "passed" without counts is rejected; every claim by a subagent is re-measured by the orchestrator before a flag flips; nothing is committed or pushed; nothing is deleted.


## Addendum 2026-11-06 07:34:41 (real `date`): items from the C5 independent re-verification

Source: `.toolchain/scratch/c5-reverify/c5-reverify-report.md`. For card G2 (section 4.1 audit) and the Polish wave:
- `security/mitm_test.dart` is listed in inc3.md section 4.1 but does not exist. Equivalent content is spread over `pinning_test`, `sas_binding_receiver_test`, `identity_proof_test`, `engine_tofu_test` and p6a 'mutation 8'. Decide: write one in-process TLS-terminating relay test (tester) or amend 4.1 to name the real files. Orchestrator decision, not the Lead's.
- Dead code: `libreshare_engine.dart:921` `if (fp == null) return _SendPlan(plaintext: true)` and the `on LsException` branch are unreachable after a successful TLS `info()`; remove or document (lib change = coder card with a tester review).
- Redundant fingerprint compare in `file_sender.dart` (~329): add a unit test with a fake `SecurePeerClient` whose `serverFingerprint` differs from the pin, or delete it.
- p6a_adversarial_test.dart: split tests 2 and 3; give test 10 a refusal-reason assertion; make the silent skip when `127.0.0.2` cannot be bound loud (CI on macOS would get zero coverage).
- TLS-floor tests (`tls_identity_test`, `engine_tls_handshake_test`, `downgrade_test`) skip without `openssl`: make CI install it or fail loudly.
- Do not trust the Lead's reports as evidence for any mutation claim; re-run.
