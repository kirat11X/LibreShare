# Decision needed: edits to 9 existing app test files (D1 round 2 side effect)

Written by the orchestrator, 2026-11-06 ~05:23 (real `date`). CLAUDE.md: "NEVER edit acceptance tests to make them pass - ask." Nothing below has been applied to the real tree. Everything was done in the scratch copy `.toolchain/scratch/d1-legacy/clone` by a high-effort tester; the diff is `.toolchain/scratch/d1-legacy/legacy-tests.diff` (310 lines, 9 files), the report is `.toolchain/scratch/d1-legacy/legacy-report.md`.

## Why this exists

The app's engine became secure (TLS, pinned certificates) when the Lead wired `security:` into `engine_provider.dart` (D1 round 1, 2026-11-06 00:56-01:20). 28 older app tests (Increment 2 / B1 / F3 era) still use PLAINTEXT fixture peers, so they went red on the real tree at that moment. My earlier "app +405 green" is from 00:19, before that edit. They are red with the old lib and with the coder's new lib alike, so the cause is the fixtures, not the new patch. The Lead's D1 round 1 reported done without a whole-suite run alone.

## A. Setup-only changes (27 tests) - I recommend approving

What changes: only how the fixture is built. No `expect`, finder, matcher, expected string or number, test name, group or timeout is touched (the tester's grep of the diff for `expect(`/`find.`/`findsOne`/`findsNothing`/`isTrue`/`isNull` finds nothing; I read the whole diff).
- `test/helpers/harness.dart`: two default-OFF static flags. `legacyPlaintextPeers` gives the app engine the existing opt-ins for plaintext devices (`allowInsecurePeers: true` and a plain `/info` probe). `securePeers` / `startPeer(secure: true)` makes a fixture peer a real secure engine with its own identity; its `sendTo` first pins the app as a known contact so no verification code appears (the same flow as before).
- 6 files (`add_device`, `f3_device_address`, `f3_failure_text`, `send_flow`, `shell_wiring`, `my_qr` scan tests) set `legacyPlaintextPeers` in `setUpAll` and clear it in `tearDownAll`; `incoming_test` sets `securePeers`; `my_qr_test` passes `secure: true` for one peer; `incoming_test` "sender gives up" passes the peer's security config to its own `ApiClient`/`FileSender`.
- `b1_settings_security_test`: an `appDirsProvider` override, a `pinGuard` getter on the fake engine, and a wait loop after tapping Save (Save is asynchronous now, which is the S1 fix).

Result in the scratch copy: the 8 changed files `+71` green in 3 of 3 runs; whole suite except the d1 files `+404 -1`; analyze and format on the 9 files rc 0.

Honest cost: the six plaintext-fixture files no longer exercise the secure path for adding and sending. The secure path for those flows is covered by the D1 tests (`d1_secure_engine`, `d1_two_engine_pin`, `d1b_sender_dialog`, which use two real secure engines) and by the core's own secure suites. Converting those six files to secure peers would change what they assert (for example `add_device` expects the "confirm fingerprint later" text), so it is not done; I list it as a follow-up for the Polish wave.

## B. One assertion that has to change (1 test) - needs your explicit yes

`settings_screen_test.dart:50`, test "shows name, folder, port and the fingerprint placeholder", expects the text `Available after security setup (a later update)`. With the secure engine the screen correctly shows the device's real fingerprint (for example `064B 8C49 316C AF2C`); the placeholder only appears for an empty fingerprint, which the real app engine can no longer have. The placeholder case is already asserted by the negative twin in `b1_settings_security_test` and the real-fingerprint case by its positive twin.

Options:
1. **(Recommended)** Change the expected value to the new correct behaviour: `matches(RegExp(r'^([0-9A-F]{4} ){3}[0-9A-F]{4}$'))` (16 hex digits in four groups of four). The test then still checks the field exists and shows a fingerprint, and gets stricter than a placeholder string.
2. Delete the 4 lines (b1 already covers both cases). Less coverage in this file.
3. Leave it red and the whole-suite gate stays red (not recommended; I cannot flip `APP_SECURE_WIRED`).

## What I do on approval

Apply `legacy-tests.diff` (and the chosen option B) to the real tree, together with the D1 round 2 lib patch and the D1 test files, then run the gate alone: all `d1*`/`d1b*` files 3x, whole app suite, analyze, format, `flutter build apk --debug`. Not before the verifier's report (`.toolchain/scratch/d1-verify/verifier-report.md`) is read.

## Update 2026-11-06 06:31 (real `date`)

After the verifier's review the coder fixed three more defects (leaving Settings during Change-PIN, selector after a failed save, retry of a completed transfer) and 4 verifier tests (`d1v_*`, 6 tests) were added. Candidate numbers are now: whole app suite alone `+471 -1` (only the Part B test is red), analyze `lib test` rc 0, format rc 0. Part A/B and my recommendation are unchanged. Nothing is applied to the real tree.

## FINAL STATE for your decision (2026-11-06 07:18, real `date`)

**Final candidate** (`.toolchain/scratch/d1-legacy/clone`; coder lib + delta fixes + 6 verifier-written test files + Part A setup changes), measured by me alone under the heavy lock: whole app suite `+475 -1` (the one red is the Part B test), `dart format` 0 changed, `dart analyze --fatal-infos lib test` clean. **Part B option 1 was proven in the scratch copy** (regexp assertion applied, then restored byte-for-byte): `settings_screen_test` + `b1_settings_security_test` `+27` all green, format and analyze rc 0. So with option 1 the whole suite should be `+476 -0` (projected; I measure it on the real tree after applying).

### C. Three D1 test files that were corrected (new in this document, no extra approval needed IF you agree they are D1's own tests; say so if you disagree)
`d1_pin_persistence_test.dart`, `d1_secure_engine_test.dart`, `d1_two_engine_pin_test.dart` were written by the Lead during D1 round 1 (2026-11-06 ~00:56-01:20) and have never been accepted. The D1 round 2 tester corrected test-side defects only: a deadlock (real-async inside the window-PIN test), vacuous `if (dir.existsSync())` guards around the 'nothing stored' checks, and missing 60 s timeouts. Strengthened, not weakened: expect count 35->41, 27->29, 14->16; test count 7->7, 8->9, 4->4; the two `expect(stored, isNull)` that moved out of the guard are kept and a new `expect(secDir.existsSync(), isTrue)` is added next to each. Real tree vs candidate diffs are in `.toolchain/scratch/d1-legacy/clone/...` (compare with `diff`).

### What exactly gets copied (script: `.toolchain/scratch/d1-apply/apply.sh`, NOT RUN)
- 9 lib files (the coder's), 12 existing test files modified (the 9 Part A files incl. `helpers/harness.dart`, plus the 3 D1 files above), 11 NEW test files (`d1b_*` x3, `d1_probe_secure_pin_test`, `d1v_*` x6, `helpers/d1b_helpers.dart`). Explicit lists only: never `test_orig/`, `bak2.dart` or `*.bak`.
- It first verifies by sha256 that the real tree has not changed since I measured it (`check` mode passed at 2026-11-06 07:18) and that the candidate is the measured one; it snapshots every file it will overwrite to `.toolchain/snap/d1-apply-<time>/`; it refuses to run without `--user-approved-A`; Part B needs the extra flag `--partB1`.
- After applying I run the gate alone: all `d1*` files 3x, the whole app suite, analyze, format, `flutter build apk --debug`; only then `APP_SECURE_WIRED: YES`.

### Known limits that stay open (not fixed, listed so you can overrule me)
First-launch race when two engine builds overlap on a brand-new key directory (core-level; very unlikely); `_closing` chaining and shutdown-while-building (reading-only findings); three LOW UX items (the 'could not save' text is invisible after a failed selector switch; a failed retry re-opens the PIN dialog silently; a user retypes a still-stored PIN after a failed switch). Each has test text in `.toolchain/scratch/d1-verify/verifier-report*.md`; I propose them for the Polish wave.

## USER DECISION (2026-11-06 08:47:24, real `date`)

The user answered (verbatim): "MAKE D1 HOWEVER U LIKE / IS FEASIBLE, 1 YA 2YA  3 WHTEVER U SAY". Read as: 1 = YES (Part A: setup-only edits to the 9 existing test files), 2 = YES (Part B option 1, the regexp for the real fingerprint), 3 = the orchestrator decides (Part C: the three corrected D1 round-1 test files are treated as D1's own tests; they only got stronger). Applying with `apply.sh apply --user-approved-A --partB1`.
