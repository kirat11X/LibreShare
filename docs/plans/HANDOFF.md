# HANDOFF: runbook for fast models (Antigravity "flash 3.8 high") and their subagents

Written 2026-11-05 by the orchestrator. Audience: a fast, literal model that follows steps well but should not improvise architecture. **Every task below is a small card with exact files, exact commands and an exact "done when". If a card does not say you may do something, you may not.**

## 0. How to use this file

1. Read `docs/plans/STATUS.md` (live progress). Then read sections 1-4 of this file once.
2. Pick a card from **Wave A** (runnable now, no collisions) or, when the STATUS flag says so, from **Wave B**.
3. Spawn ONE subagent per card using the matching template in section 6. Never give two subagents the same card or overlapping owned files (section 4).
4. When a card finishes, append its report to `docs/plans/handoff-log.md` (create it; format in section 7), then pick the next card.
5. If anything is unclear or a step fails twice: STOP, write the question to `docs/plans/questions.md` (format in section 7), and move to another card. Do not guess.

## 1. The project in ten lines

- LibreShare = free peer-to-peer file sharing, AirDrop-like, for Linux, Windows, Android (Android best-effort, macOS best-effort, no iOS). Pure-Dart core + Flutter app + Dart CLI. MIT licence. Spec: `docs/LIBRESHARE_BUILD_SPEC.md`. Protocol: `docs/protocol/LSP-1.md`.
- Repo root: `/home/kirat/coding/Software Engineering LibreShare` (**the path contains spaces: always quote it**).
- Layout: `packages/libreshare_core` (pure Dart, must never import Flutter), `packages/libreshare_cli`, `apps/libreshare_app` (Flutter UI), `docs/`, `tools/`, `deploy/`.
- Done: Increments 1-2 (transfer + discovery + app) and the building blocks of Increment 3 (TLS 1.3 with pinned certificates, signed client proof, 6-digit verification code "SAS" on first contact, PIN, consent, key-change refusal, signed goodbye, Contacts-only). Reviewed with ~180 mutation checks.
- In flight: engine + CLI wiring (P6a), Android/app usability fixes (F3).
- **Target now is an MVP** (docs/plans/mvp.md): send files Android <-> Linux (and Windows) on the same Wi-Fi, encrypted and verified, usable app. Everything else (Increments 4-7, Android background service, notifications) is **deferred: do not start it**.

## 2. Hard rules (violating any of these is a failed task)

1. **Never** `git commit`, `git push`, create a GitHub repo, or add a remote. The repo has no commits on purpose. (The user said "just initialize, don't push".)
2. **Everything must be free ($0).** No paid services, no accounts, no API keys, no new cloud dependency.
3. **Tests first.** For code work: a *tester* writes failing tests, a different *coder* makes them pass, a *verifier* reviews. A coder never edits, deletes, skips or weakens a test. If a test looks wrong, report it; do not change it.
4. **Never edit acceptance tests that already exist** (everything under `test/` that existed before your card). You may only ADD new test files named in your card. The one approved exception (the `--insecure-plaintext` setup-line flag in 2 CLI tests, `tools/loopback_smoke.sh`, `tools/docker/**`, `deploy/docker/**`) belongs to the P6a coder, not you.
5. **Real exit codes.** Run the command and read `$?` immediately. Never judge success from `... | tail`, `... | grep` or from the last printed line. Pattern: `cmd > /tmp/out.txt 2>&1; echo "rc=$?"; tail -5 /tmp/out.txt`.
6. **Never print, log, commit or paste** private keys, PINs, pairing secrets (`s=`), nonces, tokens, file contents, or full certificate fingerprints (16 hex characters is the maximum in logs and docs).
7. **No installs.** Do not run `apt`, `dnf`, `sudo`, `npm -g`, `pip install`, `flutter upgrade`, `dart pub global activate`. The toolchain is project-local (`source tools/env.sh`). Missing tool => say so in your report.
8. **Use absolute paths in every script and command**, especially anything that writes files. (A script with a relative `lib/` path once overwrote production code.) Never copy a file over `lib/` from a scratch directory.
9. **File ownership is exclusive** (section 4). Edit only the files your card lists. Do not format whole directories; run `dart format` only on files you changed.
10. Do not touch the orchestrator-owned files listed at the bottom of `docs/plans/STATUS.md`.
11. Keep `packages/libreshare_core/lib` free of `package:flutter` and `dart:ui` (check with the grep in section 3).
12. No `print()` in `packages/libreshare_core/lib` (use `package:logging`). The CLI prints on purpose.

## 3. Environment and command cheat sheet

Always start a shell with:
```bash
cd "/home/kirat/coding/Software Engineering LibreShare" && source tools/env.sh
```

| Purpose | Command | Pass means |
|---|---|---|
| Format check (whole repo) | `dart format --output=none --set-exit-if-changed . ; echo rc=$?` | rc=0 |
| Format your files | `dart format <file> <file>` | no output of "Formatted N files (N changed)" for unrelated files |
| Analyze | `dart analyze --fatal-infos ; echo rc=$?` | rc=0, "No issues found" (new red test files of other agents may cause errors: see the note below) |
| Core tests (all) | `(cd packages/libreshare_core && dart test > /tmp/core.txt 2>&1; echo rc=$?; tail -3 /tmp/core.txt)` | rc=0 |
| One core test file | `(cd packages/libreshare_core && dart test test/unit/foo_test.dart ; echo rc=$?)` | rc=0 |
| CLI tests | `(cd packages/libreshare_cli && dart test > /tmp/cli.txt 2>&1; echo rc=$?; tail -3 /tmp/cli.txt)` | rc=0 |
| App tests | `(cd apps/libreshare_app && flock /tmp/libreshare-flutter-build.lock flutter test > /tmp/app.txt 2>&1; echo rc=$?; tail -3 /tmp/app.txt)` | rc=0 (249 at last check) |
| No Flutter in core | `grep -RnE "package:flutter|dart:ui" packages/libreshare_core/lib ; echo rc=$?` | rc=1 (no match) |
| Quick loopback smoke (**only after `P6A_GATE: DONE`, one agent at a time**: it rebuilds the shared `.toolchain/ls_snapshot.dill` and the P6a coder is editing the script and the CLI) | `bash tools/loopback_smoke.sh 100 53555 ; echo rc=$?` | rc=0 |
| Build Linux + Android | `tools/package_prototype.sh linux android ; echo rc=$?` (**do NOT wrap this in `flock`**: the script takes `/tmp/libreshare-flutter-build.lock` itself, an outer flock on the same file deadlocks forever, seen 2026-11-05 23:00) | rc=0, files in `dist/prototype/` |
| Android emulator smoke | `tools/android_emulator_smoke.sh ; echo rc=$?` | rc=0, "PASS 18/18" (needs the emulator image; see docs/test-reports/android-emulator.md) |

**Notes.** (a) Wrap every `flutter test|build` in `flock /tmp/libreshare-flutter-build.lock` (several agents share one machine). (b) While other agents are mid-task, the whole-repo `dart analyze`/`dart test` can show errors or failures **in files you do not own** (red test files that are waiting for an implementation, or a half-edited engine). That is expected: run only your files, and when a whole-suite run fails, check that every failing file is NOT yours and NOT a pre-existing test before concluding anything. If a pre-existing test fails, wait 2 minutes and re-run once, then report it (with the test name) instead of fixing it. (c) The machine has a usage cap shared with other agents: do not run the full suites in a loop; run them once per card at the end. (c2) **Memory:** the machine has 15 GB RAM and ran out of memory on 2026-11-05 18:54 (many `flutter test` runs at once; the kernel killed the IDE; commands died with exit 137). Run whole-package tests only as `flock /tmp/libreshare-heavy.lock dart test -j 2` / `flock /tmp/libreshare-heavy.lock flutter test --concurrency=2`, one heavy run on the whole machine at a time, only when `free -m` shows >= 4000 MB available. Exit 137 = killed for memory, not a test result: re-run once alone. (d) No `pwsh`, `shellcheck`, `actionlint` are installed; `docker` exists; no `xvfb-run`.

**Lock leaks (found 2026-11-06 00:08):** a plain `flock /tmp/libreshare-heavy.lock tools/android_emulator_smoke.sh` lets the background `adb` server (started by the script) inherit the lock; it outlives the script and keeps the heavy lock for good, so the NEXT locked command waits forever (a packaging run waited 27 minutes). Fix: use **`flock -o`** (closes the lock fd in the child; the lock is still held while your command runs; tested) for anything that may start daemons (emulator smoke, Gradle/adb builds), i.e. `flock -o /tmp/libreshare-heavy.lock <cmd>`, and run `adb kill-server` plus `gradle --stop` (`.toolchain/gradle/wrapper/dists/gradle-9.3.1-all/*/gradle-9.3.1/bin/gradle --stop`) after the step. Diagnose a stuck lock with `lslocks | grep libreshare`: the holder with `WRITE` (no `*`) is the leaker, the one with `WRITE*` is a waiter. Stop the holder gracefully (`adb kill-server`), never `kill -9` a flock/test process you did not start.

## 4. Who owns what right now (collision map)

| Area | Owner now | You may |
|---|---|---|
| `packages/libreshare_core/lib/src/engine/**`, `receive/receive_controller.dart`, `packages/libreshare_cli/lib/**`, the 2 existing CLI tests' setup lines, `tools/loopback_smoke.sh`, `tools/docker/**`, `deploy/docker/**` | P6a coder (running) | read only |
| `packages/libreshare_core/lib/src/{server,client,transfer,security,discovery}/**` | finished packages; frozen | read only (changes go through the orchestrator) |
| `apps/libreshare_app/test/**` (new f3_* tests) | F3 tester (running) | read only until `F3_TESTS_READY: YES` |
| `apps/libreshare_app/lib/**`, `apps/libreshare_app/android/**` | nobody until Wave B | read only until your Wave B card says otherwise |
| `README.md`, `docs/dev/**`, `docs/test-reports/**` (new files), `docs/plans/handoff-log.md`, `docs/plans/questions.md` | free | Wave A cards write here |
| `docs/traceability.md`, `docs/roadmap.md` | free for Wave A cards A6 only | A6 |
| `.github/workflows/**` | free, review only | A8 writes a proposal file, not the workflow |

## 5. Task cards

Card format: **Goal / Gate / You may edit / Steps / Done when / Report.** Run the steps literally.

### Wave A: runnable now (no collisions; mostly read-only or docs)

#### A1. Baseline measurement
- Goal: a dated record of all test counts.
- Gate: none. You may edit: create `docs/test-reports/baseline-2026-11-05.md`.
- Steps: (1) run format, analyze, core, CLI, app commands from section 3, each with `; echo rc=$?` and output to `/tmp/*.txt`; (2) for each, copy the final summary line (e.g. `+2349 ~1 -9: Some tests failed`) and, if failing, the list of failing FILES (not tests): `grep -E "^\s*(\[E\]|.*Failed to load)" /tmp/core.txt | head -40`; (3) write the table `command | rc | passed | failed | failing files`.
- Done when: the file exists and every row has an rc. Do not fix anything.
- Report: the table.

#### A2. Flake hunt for the Inc 3 test files
- Goal: find tests that fail intermittently.
- Gate: `P6A_GATE: DONE` (before that the engine is mid-edit and the reds are meaningless). You may edit: create `docs/test-reports/inc3-flake-log.md`.
- Steps: (1) list the Inc 3 test files: everything under `packages/libreshare_core/test/{security,conformance}` plus `test/unit/{goodbye,peer_registry_remove,announce_fingerprint,subnet_scanner_tls,peer_registrar_tls,permission,pairing,receiver_secure_session,receiver_secure_dir,block_suggestion,api_client_tls,api_client_clock_skew,file_sender_sas,send_result_refusal,security_wiring,api_server_stop_p3}_test.dart` and `test/integration/{goodbye_registry,secure_two_engine,contacts_only_engine,path_traversal_secure,goodbye_engine}_test.dart` (skip any that do not exist yet); (2) for each file run it 3 times: `for i in 1 2 3; do (cd packages/libreshare_core && dart test <file> > /tmp/f.txt 2>&1; echo "$i rc=$?"); done`; (3) record files whose 3 results differ, or that are red 3 times (red 3 times is NOT a flake: list it separately as "red").
- Done when: the log lists every file with `3/3 green`, `flaky (n/3)` or `red`. Do not edit any test.
- Report: flaky files first.

#### A3. Security hygiene sweep (read-only audit)
- Goal: find places that could leak secrets into logs or errors.
- Gate: none. You may edit: create `docs/test-reports/inc3-hygiene-sweep.md`.
- Steps: run each grep over `packages/libreshare_core/lib` and `packages/libreshare_cli/lib` and list every hit with file:line and one sentence "safe" or "suspicious: why":
  1. `grep -RnE "print\(" packages/libreshare_core/lib` (core must have none)
  2. `grep -RnE "_log\.(fine|info|warning|severe|shout|finer|finest)" packages/libreshare_core/lib` then check whether the interpolated values include a session id longer than 8 characters, a fingerprint longer than 16 hex, a PIN, nonce, token, key, file name, or `$e`/`$err` of an unknown exception
  3. `grep -RnE "toString\(\)|message:|LsException\(" packages/libreshare_core/lib/src/{server,transfer,security,client}` for exception texts containing user or peer controlled data
  4. `grep -RnE "TODO|FIXME|XXX|HACK" packages apps --include=*.dart` (ignore hits under test/ and .dart_tool/)
  5. `grep -RnE "http://" packages/libreshare_core/lib` (plaintext URLs must only appear in the plaintext profile code paths)
  6. `grep -RnE "badCertificateCallback|allowInsecure|insecure" packages/libreshare_core/lib packages/libreshare_cli/lib`
- Done when: the file lists all hits. **Do not edit code.** The orchestrator decides what to fix.
- Report: the "suspicious" items only.

#### A4. README refresh
- Goal: README matches reality.
- Gate: none. You may edit: `README.md` only.
- Steps: (1) read README.md, `docs/plans/mvp.md`, `docs/plans/STATUS.md`, `docs/dev/testing-prototype.md`; (2) keep every existing section that is still true; (3) add/replace a "Status" section: Increments 1-2 done, Increment 3 secure transfers in progress, MVP target, link to `docs/plans/mvp.md` and `docs/dev/testing-prototype.md`; (4) in "Install" keep the Linux/Android/Docker instructions, mark Windows as "build via Windows PC or GitHub Actions; not built yet"; (5) add a "Known limits" list copied from `docs/dev/prototype-1.md` (update the encryption line: transfers are encrypted from the secure build on; the older prototype APKs are not); (6) no claims that are not backed by a doc in the repo.
- Done when: `grep -n "TODO" README.md` has no hits and every relative link in README points to an existing file (`for f in $(grep -oE "\]\(([^)#]+)" README.md | sed 's/](//'); do [ -e "$f" ] || echo "BROKEN $f"; done` prints nothing).
- Report: sections changed.

#### A5. Demo guide (draft)
- Goal: one page the user can follow to show the MVP.
- Gate: none for the draft. You may edit: create `docs/dev/demo-mvp.md`.
- Steps: (1) read `docs/plans/mvp.md` (demo script), `docs/dev/testing-prototype.md` (real button labels), `docs/test-reports/android-emulator.md` (labels, known problems); (2) write: prerequisites; install on Linux and Android; the 5-step demo script with the exact labels from the emulator report; for steps that depend on unfinished work (SAS code screens, PIN setting, fingerprint in Settings) write the step but prefix the line `[PENDING: MVP-App]`; a troubleshooting table (same Wi-Fi, firewall ports UDP 53318 and TCP 53318-53327, AP isolation, "Could not reach", app must stay open); (3) a "What this MVP does not do" list from `docs/plans/mvp.md` OUT section.
- Done when: the file exists, every UI label you quote appears in the emulator report or testing guide (`grep -F` each one), and every `[PENDING: MVP-App]` line is listed at the top.
- Report: the PENDING list.

#### A6. Traceability update for Increment 3
- Goal: requirement table points at real tests.
- Gate: none. You may edit: `docs/traceability.md` only.
- Steps: (1) read it and `docs/plans/inc3.md` section 4; (2) for FR-05, FR-06, FR-16, FR-18 (Contacts-only part) and NFR-04, add the Increment 3 test files that cover them (use `ls`/`grep -l` to confirm each file exists; never list a file that does not exist); (3) add the status words "building blocks reviewed" or "engine wiring pending" as appropriate; do NOT write "verified" unless you ran that file in this card and it exited 0 (record the date and command); (4) leave the other rows untouched.
- Done when: every file named in your edits exists (`ls`) and the git-free diff of the file is only those rows.
- Report: rows changed.

#### A7. Static review of the install scripts (never executed on Windows)
- Goal: find bugs by reading, because `pwsh` is not installed.
- Gate: none. You may edit: create `docs/test-reports/install-scripts-review.md`. Do not edit the scripts.
- Steps: (1) `bash -n deploy/install.sh tools/*.sh tools/docker/*.sh deploy/docker/entrypoint.sh ; echo rc=$?` (syntax only); (2) read `deploy/install.ps1` line by line with this checklist: `Set-StrictMode`/`$ErrorActionPreference`, every external command's exit code checked (`$LASTEXITCODE`), paths with spaces quoted, `Join-Path` used, no Linux-only commands, Docker Desktop in Linux-container mode check, firewall commands printed but never run, uninstall only deletes the data folder after typing `delete` and only if the marker file exists, no secrets printed, works in Windows PowerShell 5.1 (no `??`, no `&&`/`||` chaining, no ternary); (3) list findings with line numbers and a severity.
- Done when: the review file exists with the checklist results (pass/fail per item).
- Report: findings with severity High/Medium only.

#### A8. CI workflow proposal
- Goal: CI runs the new tests.
- Gate: none. You may edit: create `docs/plans/ci-proposal.md`. Do not edit `.github/workflows/*`.
- Steps: (1) read `.github/workflows/ci.yml` and `prototype.yml`, CLAUDE.md "Commands"; (2) list which jobs exist and which of: format, analyze, core tests, CLI tests, app tests, loopback smoke, Docker e2e, Linux build, Android build are missing; (3) write the proposed YAML fragments for the missing jobs (Ubuntu runner, Flutter 3.47.9 via `subosito/flutter-action@v2`, `LS_CI=1` for scripts, `continue-on-error` only on flaky/unverified Windows steps); (4) note that Windows jobs are untested.
- Done when: the proposal exists and each fragment is valid YAML (check by reading; no tool available).
- Report: missing jobs list.

#### A9. Windows readiness audit (read-only)
- Goal: list code that will probably break on Windows, since no Windows build is possible here.
- Gate: none. You may edit: create `docs/test-reports/windows-readiness.md`.
- Steps: grep `packages/*/lib` and `apps/libreshare_app/lib` for: `Platform.isLinux|isWindows|isAndroid`, `chmod`, `Process.run|Process.start`, hard-coded `/` path joins (use of `'/'` in path code instead of `package:path`), `HOME|XDG_`, `USERPROFILE|APPDATA`, `dart:io` `File.setLastModified`, `FileMode.append` plus `setPosition` (known Windows risk), `Link(`, reserved Windows file names handling in `filename_sanitizer.dart` (CON, PRN, AUX, NUL, COM1..9, LPT1..9, trailing dots/spaces, `:`), long paths. For each hit write "ok / risk / needs Windows test" with file:line.
- Done when: the file lists every hit. Do not edit code.
- Report: the "risk" items.

#### A10. Licence and dependency audit
- Goal: prove all dependencies are free and compatible with MIT.
- Gate: none. You may edit: create `docs/dev/licences.md`.
- Steps: (1) `dart pub deps --style=list > /tmp/deps.txt` in each of `packages/libreshare_core`, `packages/libreshare_cli`, `apps/libreshare_app` (use `flock` + `flutter pub deps` for the app); (2) for each direct dependency read its licence from the local pub cache (`$PUB_CACHE/hosted/pub.dev/<pkg>-<ver>/LICENSE`) and record SPDX-style name; (3) flag anything that is not MIT/BSD/Apache-2.0/MPL/ISC; (4) note the Google ML Kit dependency pulled by `mobile_scanner` (Android) and that phones without Google services are unverified.
- Done when: every direct dependency has a row (name, version, licence, path of the LICENSE file read).
- Report: any non-permissive licence.

### Wave B: gated (start only when the flag in STATUS.md says so)

Flow for every Wave B code card: **tester card -> coder card -> verifier card**, three separate subagents, in that order, never merged. Templates are in section 6.

#### B1. MVP-App security screens  (gate: `P6A_GATE: API-READY` or `DONE`; the engine/CLI API is frozen, the remaining Wave C items do not change it)
- Needed behaviour (all in `apps/libreshare_app/lib`; engine API names are in `docs/plans/inc3-p6a-tests.md` and the finished engine, read them first):
  1. **Incoming transfer dialog** (existing "Incoming transfer"): if `IncomingSessionInfo.sasRequired`: show the heading "Verification code", the digits grouped `482 913` in a large font, the sentence "Ask {sender} to read the code on their screen. Accept only if it is the same." and keep **Accept disabled until `sasCode != null`**; show a badge from `PeerTrust`: "New device" (unknown), "Known device" (known), "Trusted contact" (trusted). If `keyChanged`: show a red banner "This device's security key changed. It may be a new phone, or someone pretending to be it." with **no Accept button** (Reject only) and a link to Contacts.
  2. **Sender progress**: after `SasReady(outgoing: true)` show "Verification code 482 913. Tell {peer} to compare it, then wait for them to accept." plus Cancel. Map `PeerKeyChanged` to "The security key of {peer} changed. Nothing was sent." and `InsecurePeerException` to "{peer} uses an older version without encryption. Nothing was sent."; PIN required => PIN entry dialog (6 digits); wrong PIN => "That PIN was not accepted." (never show attempt counts).
  3. **Settings**: "Your fingerprint" (16 hex in groups of 4 plus a copy button; replaces the text "Available after security setup (a later update)"); "PIN" selector Off / Fixed / New each time Receive is on (fixed shows an input for the 6 digits; PIN is never shown again after saving except in the Receive-window mode where it is displayed while Receive is on); "Contacts" list with remove and block (trust level text).
  4. Storage: the engine's file-based secret store in the app support directory is used for the MVP (no `flutter_secure_storage`).
  5. Out of scope: QR pairing screen, Contacts-only toggle, notifications.
- Done when (verifier): new widget tests pass, the 249 existing app tests still pass, `dart analyze --fatal-infos` clean for `apps/libreshare_app/lib`, and the screens render at 360x640 with 1.3x text scale without overflow (a widget test asserts no `RenderFlex overflow` exceptions).

#### B2. F3 verification  (the F3 tester and coder are DONE, see STATUS.md; this card is the VERIFIER only)
- Spec = `docs/plans/f3-tests.md`. Do not edit `apps/libreshare_app/lib/**` or `android/**`; add NEW test files only (`apps/libreshare_app/test/f3_review_*_test.dart`).
- Work in a scratch clone (never mutate the real tree). Run the "Recommended mutation checks" listed at the bottom of `f3-tests.md` (asked-flag never saved; `describeSavedLocation` matching "Download" anywhere; no unit rollover; launcher returning true on error; flag ignored in `failureText`; FAB padding 0; trim after truncate in `resolveDeviceAlias`; prompt shown after Receive on): each must turn at least one named test red; a mutation that stays green = write a new test.
- Read the Kotlin: `apps/libreshare_app/android/app/src/main/kotlin/dev/libreshare/libreshare_app/FileOpenerChannel.kt` and `DeviceInfoChannel.kt`. Answer in the report: (1) can the file-opener open or share a path OUTSIDE the receive folder (FileProvider paths expose shared storage root-wide, `external-path "."`)? it should refuse a missing file and anything that is not a regular file; (2) is the MIME type derived from the extension only; (3) no secrets logged. Do not fix Kotlin: write findings to `questions.md` (ESCALATE-SECURITY if (1) is yes).
- Report the app suite counts from a clean run alone under the heavy lock (the orchestrator measured +372 -2 at the F3 gate; the 2 reds are the device-address tests until C3).
- Open items from the coder: an incoming transfer that fails with `noConnection` after data moved now also says "connection lost" (acceptable); the tray toggle and visibility control do not trigger the storage prompt (acceptable for the MVP).

#### B3. Rebuild, repackage, emulator re-test  (gate: `MVP_APP_DONE: YES`)
- **Deadlock warning:** run `tools/package_prototype.sh` bare (no outer `flock`). If a packaging command shows no `flutter`/`dart` child process for more than 3 minutes, check `lslocks | grep libreshare`: a `WRITE*` entry means it is waiting on its own lock; kill that command and re-run it bare.
- Steps: (1) `tools/package_prototype.sh linux android ; echo rc=$?`; (2) `(cd dist/prototype && sha256sum -c SHA256SUMS ; echo rc=$?)`; (3) `tools/android_emulator_smoke.sh ; echo rc=$?` (needs the emulator image under `.toolchain/`; if absent say so, do not install); (4) update `docs/dev/testing-prototype.md` and `docs/dev/demo-mvp.md` (remove the `[PENDING: MVP-App]` prefixes only for steps you actually saw work on the emulator, with the screenshot or log line as evidence).
- Done when: all three commands rc=0 or the missing prerequisite is reported.

#### B4. MVP acceptance checklist  (gate: B1, B2, B3 done)
Run, in order, and write the table into `docs/test-reports/mvp-acceptance.md`: format rc, analyze rc, core rc and counts, CLI rc and counts, app rc and counts, `tools/loopback_smoke.sh 100 <free port>` rc and MiB/s, `tools/package_prototype.sh linux android` rc, emulator smoke rc, grep-no-flutter-in-core rc=1. Anything non-zero: stop and report; do not fix other agents' areas.

### Wave C: P6a / F3 follow-ups (added 2026-11-05 evening; run by YOUR subagents, the orchestrator spawns no more agents)

Background: the P6a coder's report was partly verified (see STATUS.md). Two Claude agents are still running and must not be disturbed: the tester T2 (works in a scratch clone, delivers files under `.../scratchpad/t2/deliver/`) and the F3 coder (owns `apps/libreshare_app/lib/**` and `apps/libreshare_app/android/**` until it reports). **The orchestrator applies the T2 test files to the real tree and flips `WAVE_C_READY: YES` in STATUS.md; do not start C1-C4 before that flag.** Same tester -> coder -> verifier flow; tests already exist for all four cards.

#### C1. `FileReceiver.getSession` follows LSP-1 section 4.3  (security-critical file: change EXACTLY the condition, nothing else)
- Test (already written by T2, red today): `packages/libreshare_core/test/unit/receiver_session_wait_test.dart`.
- Coder may edit: `packages/libreshare_core/lib/src/transfer/file_receiver.dart`, only the `getSession` method (around line 624): hold the long poll only while `s.status == TransferStatus.pending` (a session past PENDING answers immediately; wait = 0 immediate; terminal immediate). No other line.
- Done when: the new file passes 3 times; `test/unit/receiver_*`, `test/security/p4_review_test.dart`, `test/conformance/api_conformance_test.dart` and `test/conformance/api_conformance_secure_test.dart` still pass (run each alone, `flock /tmp/libreshare-heavy.lock dart test -j 1 <file>`).
- Verifier (different subagent): in a scratch clone put the old condition back and show the new test turns red; then confirm `git`-free diff of the real file is that one condition.
- Escalate to the orchestrator before merging: **ESCALATE-SECURITY gate**, the orchestrator re-runs it.

#### C2. Remove the engine workaround and the CLI import hack  (only after C1 is verified)
- Coder may edit: `packages/libreshare_core/lib/src/engine/libreshare_engine.dart` only (delete the `_EngineReceiver.getSession` override and the comment above it; keep the class if it still overrides anything else, otherwise use `FileReceiver` directly). The CLI import cleanup in `ls_cli.dart` and 7 redundant test imports were already done by the orchestrator (analyze of those dirs rc=0).
- Done when: `dart analyze --fatal-infos lib` rc=0 in `packages/libreshare_core` and `packages/libreshare_cli`; `test/integration/secure_two_engine_test.dart`, `test/security/engine_tofu_test.dart` and `packages/libreshare_cli/test/cli_security_test.dart` pass; a secure send with SAS no longer stalls (secure_two_engine must finish well under 25 s).

#### C3. `PeerRegistry.seen` keeps a manual/QR address  (discovery; touches pinned-entry logic, so read the P6b tests first)
- Tests: `apps/libreshare_app/test/f3_device_address_test.dart` (red today), plus the existing registry tests that must stay green: `packages/libreshare_core/test/unit/peer_registry_test.dart` (if present), `peer_registry_remove_test.dart`, `announce_fingerprint_test.dart`, `security/p6b_review_test.dart`, `integration/goodbye_registry_test.dart`.
- Rule (from `docs/plans/f3-tests.md`): a manual/qr entry keeps its address and source when a non-manual source reports another address; a manual/qr sighting still replaces it; other devices still follow the latest address. **The pinned-fingerprint rules must not change** (pinned entry unchanged by an empty/different fingerprint; flag only for a different non-empty one).
- Coder may edit: `packages/libreshare_core/lib/src/discovery/peer_registry.dart` only.
- Done when: the f3 device-address file passes 3 times in the app project (needs the heavy lock + `flutter test --concurrency=1`) and all registry tests above pass.

#### C4. Full P6a gate (the verifier of Wave C runs it; the orchestrator re-runs it)
Order, each alone under the heavy lock, rc after each: `dart analyze --fatal-infos` (repo root), `dart format --output=none --set-exit-if-changed .`, core `dart test -j 1` (final line `+N ~M -K`), CLI `dart test -j 1`, `bash tools/loopback_smoke.sh 100 <free port>` (record MiB/s from its output), app suite after the F3 coder has reported, `grep -RnE "package:flutter|dart:ui" packages/libreshare_core/lib` (rc 1). Anything red: list the failing FILES and stop.

#### C5. P6a adversarial review  (security-critical: the required second tester review; run after C1+C2, reads the engine, edits no lib)
- Verifier works in a scratch clone only. Scope: `packages/libreshare_core/lib/src/engine/{libreshare_engine,security_wiring,discovery_config}.dart` and `packages/libreshare_cli/lib/ls_cli.dart` against `docs/plans/inc3-p6a-tests.md` and `docs/plans/inc3.md` section 4.1 (security checklist).
- Seeded mutations (each must turn at least one NAMED test red; write a new test file for any that stays green): (1) engine ignores `allowInsecurePeers=false` after the legacy plaintext probe (downgrade must be refused with `InsecurePeerException`); (2) skip the pinned-fingerprint comparison on the secure send path; (3) do not raise key-changed when a known device id shows a different key; (4) engine passes `pinVerifier: null`; (5) PIN or fingerprint longer than 16 hex written to a log record; (6) CLI maps `PeerKeyChanged` to exit 1 instead of 80 (and 81/82/83/84 analogously); (7) CLI `--insecure-plaintext` accepted but ignored (still TLS) and the opposite (flag missing but plaintext used); (8) `receive` auto-accepts a first-contact transfer without showing the SAS code; (9) identity directory not persisted (restart loses the pin); (10) Contacts-only setting not wired (strangers answered).
- Plus: run each P6a test file 3 times, read the CLI help text for the new flags, list any flag whose default is insecure.
- Report: mutation table (mutation, test that went red or NEW test), findings by severity with file:line, verdict. Findings with severity High go to `questions.md` as ESCALATE-SECURITY.

### Wave D: found by the orchestrator's oversight review (2026-11-05 ~23:05). MVP BLOCKER first.

**Finding (verified by reading the code, not by a test):** `apps/libreshare_app/lib/providers/engine_provider.dart` builds `LibreShareEngine(...)` with **no `security:` argument**, and the engine treats `security == null` as the plaintext profile (`_secure => security != null`). So today the **app does not use TLS, SAS, pinning, PIN or contacts at all**; the B1 screens (verification code, key-changed banner, fingerprint, contacts) never get data, and the Settings **PIN "Save" button only sets a widget flag (`_pinSaved = true`) and discards the digits**, then shows "PIN configured". That is a security control that does nothing. B1 was reported DONE because its tests inject fake engines. Consequence: `MVP_APP_DONE` stays `NO`; APKs/tarballs built before D1 are PLAINTEXT builds and must not be shown as "encrypted".

#### D1. Wire the app to the secure engine and make the PIN real  (SECURITY-CRITICAL: tester -> coder (medium) -> verifier; the orchestrator re-runs the gate)
- Tester writes NEW tests first in `apps/libreshare_app/test/d1_*_test.dart` (show them red; never edit old tests): (1) the engine built by `engineProvider` has `engine.identity != null` and `engine.deviceInfo.fingerprint` non-empty (secure profile) using a temp support dir; (2) a second build with the same support dir has the SAME fingerprint (identity persisted under `<supportDir>/security`); (3) a missing/damaged key makes the provider fail with a clear error and does NOT silently create a new identity (core throws `IdentityLostException`); (4) PIN mode Off -> `engine.pinGuard.enforced == false`; Fixed + saved 6 digits -> enforced and the saved PIN survives an app restart (new provider container) and is NOT present in `app_settings` JSON, logs, or `toString()` output; (5) "New each time" -> `currentPin` is non-null while Receive is on and changes on the next Receive window (`PinGuard.rotate`), and the PIN is shown on the Receive card only while Receive is on; (6) wrong 6-digit input (5 digits, letters) is rejected with a visible message and nothing is saved; (7) the sender-side PIN dialog (B1) still works against a real secure receiver (two engines in one test, like core `secure_two_engine_test`); (8) `allowInsecurePeers` is false by default and a plaintext peer produces the existing "uses an older version without encryption" message.
- Coder may edit only `apps/libreshare_app/lib/**` (plus new tests are not theirs). Design (fixed by the orchestrator, do not improvise):
  * In `EngineNotifier.build()`: `final security = await SecurityWiring.open(directory: Directory(p.join(dirs.supportDir.path, 'security')), deviceId: identity.$1, pinPolicy: <from settings>, pin: <fixed PIN or null>);` and pass `security: security` to `LibreShareEngine`. Keep the wiring in a provider (or field) so a rebuild reuses nothing stale; the engine does NOT close it: call `security.close()` in the same `ref.onDispose` that closes the engine, after the engine is closed. `SecurityWiring` and `PinPolicy`/`PinMode` come from the core barrel (`package:libreshare_core/libreshare_core.dart`); do NOT import `src/`.
  * PIN persistence: mode (off/fixed/window) in `AppSettings` (new field, default off). The fixed PIN goes ONLY into `FileSecretStore(Directory('<supportDir>/security'))` under the name `app-pin` (`put(name, Uint8List)` / `get`), never into settings JSON. Changing the mode or saving a PIN rebuilds the engine (the existing watch-settings mechanism). Settings screen: replace the fake `_pinSaved` flag by a real call; show "PIN configured" only after the save really succeeded; "New each time" shows no input.
  * `deviceId` must equal the stored identity's id (the engine throws `ArgumentError` otherwise): on first run pass the settings device id to `SecurityWiring.open`; if an identity already exists its id wins, so read it back and make settings follow it (or fail with a clear message, do not loop).
  * Never log or display secrets: no PIN, no private key, no fingerprint longer than the 16-hex display form, in any log, error text, or `toString`.
  * Desktop and Android only need the file store (no keychain) for the MVP.
- Verifier (different subagent; scratch clone only) mutations, each must turn a named test red (else write a new test): (a) `security:` not passed; (b) new identity generated on every start; (c) the fixed PIN written to the settings JSON; (d) PIN accepted unsaved / "PIN configured" shown on failure; (e) window PIN does not change between Receive windows; (f) `IdentityLostException` swallowed and identity regenerated; (g) PIN text appears in a log record; (h) `allowInsecurePeers: true` default.
- Done when: the new tests 3x green, the whole app suite green (alone, heavy lock), `dart analyze --fatal-infos` rc 0, `flutter build apk --debug` rc 0, the verifier PASS. Then the orchestrator re-runs and flips `APP_SECURE_WIRED: YES`.

#### D2. Hygiene left by Wave B/C  (quick, any subagent)
- `dart format` the 3 B1 test files (`apps/libreshare_app/test/b1_*_test.dart`) and add the missing `@override` on `isListening` and `port` in `test/b1_settings_security_test.dart` (lines ~46-47). Do not change any assertion. Done when repo-wide `dart format --output=none --set-exit-if-changed .` and `dart analyze --fatal-infos` are both rc 0.
- `docs/plans/handoff-log.md` C4 entry says DONE although its own core run was rc=1 (-18 port collisions) and the CLI run rc=1 (-1): correct the entry. Port collisions and A2's "2 files red 3/3 (EADDRINUSE)" were caused by running while other agents ran tests; the orchestrator's clean runs have no such failures. Rule: a gate request must list EVERY command's rc, including the red ones.

#### D3. P6a adversarial review (C5) is still outstanding. Run it before `P6A_GATE: DONE`.

#### D4. Android file opener (answer to Q2 in questions.md): accepted for the MVP, plus one cheap hardening
- `FileOpenerChannel.kt`: refuse (return false) when the path is not an existing regular file, when `canonicalPath` is not under external storage or the app's external files dir, or contains a private-data prefix (`/data/`). No change to the channel contract (so no test change). Add the Kotlin note to the verifier report. Low priority.

#### D5. Re-package after D1  (B3 again)
**OWNER: the ORCHESTRATOR (user decision 2026-11-06 03:24), not the Lead.** The Lead must not run the package script or the emulator smoke.
Any build made before `APP_SECURE_WIRED: YES` is informational only (it is plaintext). After D1: `tools/package_prototype.sh linux android`, `tools/android_emulator_smoke.sh`, and a manual check on the emulator: first send between two devices shows the same 6-digit code on both screens.

### Deferred (do NOT start; listed so nobody does by accident)
Android background receive service (P9), notifications, QR pairing screen, Contacts-only toggle UI, extra Docker e2e (P10), Windows secure key store, Increment 4 (connection ladder / resume / hashing speed), Increment 5 (internet tunnel, share link), 5b, Increment 6 (free rendezvous), Increment 7 (BLE + hotspot), Polish. They stay in `docs/roadmap.md`.

## 6. Subagent prompt templates (copy, fill the `{...}`, send)

**Common preamble (put at the top of every prompt):**
```
You work on LibreShare in "/home/kirat/coding/Software Engineering LibreShare" (path has spaces: quote it, use ABSOLUTE paths).
First run: cd "<repo>" && source tools/env.sh
Read, in this order: docs/plans/STATUS.md, docs/plans/HANDOFF.md sections 2 and 3, then your card {ID} in section 5.
Do exactly the steps of your card. You may edit only the files the card lists. Do not git commit or push. Do not install anything.
Read the real exit code of every command (cmd > /tmp/x.txt 2>&1; echo rc=$?). If a step fails twice or the card is unclear, STOP and write the question to docs/plans/questions.md, then report.
Final message: at most 200 words in the report format of HANDOFF.md section 7.
```

**Tester template:** `Role: TESTER. Write FAILING tests first for {feature} in NEW files {paths} only. Never edit lib/ or existing tests. Each test must be able to fail (include a negative case and a positive twin). Run each new file 3 times. Show the red output and say why it is red. Write docs/plans/{id}-tests.md: files, one line per group, new symbols with signatures, red-state table.`

**Coder template:** `Role: CODER. Make the tests in {test paths} pass by editing ONLY {lib paths}. Never edit, delete, skip or weaken any test; if a test looks wrong, STOP and report it. Run the new tests 3 times, then the pre-existing suites listed in the card, then format and analyze for your files. Report exact pass/fail counts.`

**Verifier template:** `Role: VERIFIER (adversarial reviewer). Do not edit lib/. Read the diff area {lib paths} against the spec {doc}. Do mutation checks ONLY in a scratch copy of the repo under /tmp/claude-1000/.../scratchpad/<name>/clone (never in the real tree): apply a bug, run the minimum tests, record red/green, restore, compare with cmp. Any mutation that stays green = write a new test for it (new file). Report findings by severity with file:line, the list of new red tests the coder must fix, and a verdict.`

**Auditor template (Wave A read-only cards):** `Role: AUDITOR. Read-only: do not edit code or tests. Produce only the report file named in the card.`

## 7. Report and question formats

`docs/plans/handoff-log.md` entry:
```
## {card ID} {title} - {date time}
Result: DONE | PARTIAL | BLOCKED
Commands run (with rc): ...
Files created/changed: ...
Findings / numbers: ...
Open questions: (see questions.md #n) or none
```
`docs/plans/questions.md` entry:
```
### Q{n} {date} from {card ID}
Question (one sentence):
What I tried / what I read:
Options I see (max 3):
What I will do meanwhile: (switch to another card)
```

## 8. Stop conditions (stop the whole run and tell the user)

- A command would push, commit, install, spend money, or need an account.
- A pre-existing test fails twice in a row after a 2-minute wait and it is not in a file you own.
- You are about to edit a file outside your card.
- Disk full, `.toolchain/` missing, or `source tools/env.sh` fails.
- Anything that looks like a secret ended up in a file or log: remove it from the file you created and report (do not paste it into the report).

## 8b. Escalation: what stays with the orchestrator (Claude, extra-high)

The fast models do the volume work (Wave A audits/docs, Wave B tester/coder/verifier cards for UI and app plumbing). The orchestrator is kept for the things below. **Do not attempt these yourself; write a ticket and move to another card.**

| Escalate when | Ticket |
|---|---|
| Any change to security-critical code: crypto, TLS/auth, trust store, pairing, PIN guard, key storage, SAS, `server/api_server.dart`, `transfer/file_receiver.dart`, `security/**` | `questions.md` entry titled `ESCALATE-SECURITY`; the orchestrator spawns a medium+ coder and a second tester |
| A test fails and you do not understand why after two honest attempts (read the test, read the code, run only that test) | `ESCALATE-DEBUG` with: test name, exact failing assertion text, the 3 commands you ran, what you think is wrong |
| A flaky test (A2 shows `flaky`) | `ESCALATE-FLAKE` with the 3 run outputs' differing lines |
| A test looks wrong or contradicts the spec/protocol | `ESCALATE-SPEC` (you must not edit it) |
| A protocol/contract change seems needed (`protocol.dart`, `model/*`, interfaces, LSP-1.md, schemas) | `ESCALATE-CONTRACT` |
| Something works on the emulator but you suspect it would not on Windows or a real phone | `ESCALATE-PLATFORM` |
| Any gate in STATUS.md is ready to flip, or a card claims "DONE" on a Wave B code card | the orchestrator re-runs the gate by real exit codes before the flag flips. **A card's own "DONE" is never the gate.** |

Rule of thumb: if a fix would take more than ~40 lines in `lib/` outside `apps/libreshare_app/lib`, or touches more than 3 files, or you are unsure which package owns it, escalate instead of editing.

## 9. After Wave B

When B4 is green the orchestrator re-measures, updates `docs/plans/mvp.md` and `STATUS.md`, and the user decides whether to build the Windows app (needs a Windows PC or a private GitHub repo + Actions, which requires the user's explicit approval) or to continue with the deferred list.
