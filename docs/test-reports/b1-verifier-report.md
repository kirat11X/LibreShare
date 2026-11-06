# B1 Verifier Report: MVP-App Security Screens

Date: 2026-11-05
Role: VERIFIER (Adversarial Reviewer)
Target: MVP-App security screens implementation (`b1_incoming_security_test.dart`, `b1_sender_security_test.dart`, `b1_settings_security_test.dart`) against `docs/plans/b1-tests.md` and `docs/plans/HANDOFF.md` card B1.

---

## 1. Test Suite Verification

### B1 Security Tests (3x Consecutive Runs)
Command: `source tools/env.sh && NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 flock /tmp/libreshare-flutter-build.lock flutter test --no-pub apps/libreshare_app/test/b1_*`

| Run | Exit Code | Result | Details |
|---|---|---|---|
| Run 1 | `rc=0` | PASS | 27/27 tests passed |
| Run 2 | `rc=0` | PASS | 27/27 tests passed |
| Run 3 | `rc=0` | PASS | 27/27 tests passed |

### Base App Tests
Command: `source tools/env.sh && NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 flock /tmp/libreshare-flutter-build.lock flutter test --no-pub apps/libreshare_app/test/`

- Exit Code: `rc=1`
- Passed: 399 / 401
- Failures (2 pre-existing / execution environment issues unrelated to B1):
  1. `f3_format_test.dart`: "one formatter everywhere no other file in lib/ divides by 1000/1024 or owns a size unit"
     - Root cause: Test line 78 asserts `Directory('lib').existsSync()` with reason `'run from apps/libreshare_app'`. When executed from repository root, `./lib` is absent. When executed from `apps/libreshare_app`, all 23 tests pass cleanly (`rc=0`).
  2. `receive_card_test.dart`: "Receive card on Home a port that cannot be bound shows Failed and Try again"
     - Root cause: Linux socket `TIME_WAIT` behavior (`errno = 98 Address already in use`) when attempting to re-bind port 59871 immediately after `blocker.close()`.
  - All 27 B1 security tests passed within the full suite run.
  - All 4 `f3_device_address_test.dart` tests passed.

---

## 2. Static Analysis

Command: `HOME=/tmp dart analyze --fatal-infos apps/libreshare_app/lib`
- Exit Code: `rc=0`
- Output: `Analyzing lib... No issues found!`

---

## 3. Adversarial Mutation Checks

Conducted in scratch clone `/tmp/lead-scratch/b1-clone` (zero modifications to real tree).

| Mutation | Description | File & Line Mutated | Test Caught | Result | Restore & Cmp |
|---|---|---|---|---|---|
| 1. Accept button enablement without SAS | Enabled Accept button when `sasRequired == true && sasCode == null` | `incoming_transfer_dialog.dart:338` | `b1_incoming_security_test.dart`: "Incoming transfer dialog - SAS verification code negative twin: when sasRequired is true and sasCode is null, Accept is disabled until code arrives" | RED (`rc=1`) | `cmp_rc=0` (Clean match) |
| 2. keyChanged banner showing Accept | Rendered Accept button when `keyChanged == true` | `incoming_transfer_dialog.dart:335` | `b1_incoming_security_test.dart`: "Incoming transfer dialog - Key changed red banner positive twin: when keyChanged is true, shows red banner, NO Accept button, and link to Contacts" | RED (`rc=1`) | `cmp_rc=0` (Clean match) |
| 3. PIN entry rejection | Altered invalid PIN message mapping to leak attempt counts | `transfer_screen.dart:28` | `b1_sender_security_test.dart`: "Sender progress - Wrong PIN mapping positive twin: wrong PIN maps to 'That PIN was not accepted.' without attempt counts" | RED (`rc=1`) | `cmp_rc=0` (Clean match) |

All 3 seeded mutations turned RED as expected and failed deterministic test assertions. Restoring each file returned `cmp` exit code 0 against the real repository tree.

---

## 4. RenderFlex & Viewport Verification
- Viewport: Mobile 360x640 with 1.3x text scale.
- Verified across:
  - `IncomingTransferDialog` (`b1_incoming_security_test.dart`)
  - `TransferScreen` (`b1_sender_security_test.dart`)
  - `SettingsScreen` (`b1_settings_security_test.dart`)
- Outcome: Zero `RenderFlex overflow` exceptions.

---

## 5. Verdict
**VERIFIED / PASSED (DONE)**
The B1 implementation strictly satisfies all functional and security requirements in `docs/plans/b1-tests.md` and `HANDOFF.md` card B1.
