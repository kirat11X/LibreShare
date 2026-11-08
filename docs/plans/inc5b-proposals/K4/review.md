# Review: Card K4 (CLI/App Toggles, Disclosure & Port Range)

**Reviewer:** Antigravity Independent Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc5b-proposals/K4/`  
**Verdict:** ACCEPT  

---

## 1. Scope
- **Files added/changed in `patch.diff`:** (2 files, matches `grep -c '^--- ' patch.diff` = 2)
  1. `docs/user/guide.md`
  2. `packages/libreshare_cli/lib/ls_cli.dart`
- **Test files:**
  1. `packages/libreshare_cli/test/link_hide_ip_test.dart`
  2. `apps/libreshare_app/test/widgets/hide_my_ip_test.dart`
- **Spec / Plan references:**
  - `docs/plans/inc5b.md` Section 1, 2, 4 (Wave 4: App/CLI toggles, disclosure line, "Hide my IP", firewall guide)
  - `docs/design/04-link-qr-and-free-internet-paths.md` section 5.4 (D1 port mapping default OFF, D5 IP disclosure notice)

---

## 2. Diff Read
- `docs/user/guide.md` (lines 1-25): Updates documentation for firewalld, ufw, and Windows Defender to reflect the direct origin port range `53318-53349/tcp`. **Verdict: OK.**
- `packages/libreshare_cli/lib/ls_cli.dart` (lines 26-55): Adds `--hide-ip` flag to `link` command, adds `--port-map` flag (default off per D1), and emits mandatory `DISCLOSURE:` or `HIDE-IP:` notice before link generation. **Verdict: OK (Security-Relevant: guarantees user awareness of IP exposure).**

---

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Mandatory IP Disclosure Output | `link command prints DISCLOSURE notice when --hide-ip is absent` | Proves stdout contains `DISCLOSURE: Direct internet paths include your public IP address. Pass --hide-ip for tunnel only.`. |
| Hide-IP Tunnel Enforced Output | `link command prints HIDE-IP confirmation when --hide-ip is set` | Proves stdout contains `HIDE-IP: Direct candidates omitted. Tunnel-only routing active.`. |
| App UI Hide My IP Toggle | `CreateLinkSheet renders and toggles Hide My IP switch` | Proves widget contains `Key('hide_ip_toggle')` with disclosure subtitle and responds to user taps. |

---

## 4. Mutation Table
| Mutation Description | Target File / Line | Red Test Result | Post-Restore Diff |
|---|---|---|---|
| Remove `DISCLOSURE:` notice branch when `--hide-ip` is false | `ls_cli.dart:1835` | `link_hide_ip_test.dart` FAIL (missing disclosure line) | clean (`diff -r` rc=0) |
| Remove `HIDE-IP:` confirmation when `--hide-ip` is true | `ls_cli.dart:1837` | `link_hide_ip_test.dart` FAIL (missing hide-ip line) | clean (`diff -r` rc=0) |
| Invert default value of `_hideIp` in `CreateLinkSheet` | `create_link_sheet.dart:36` | `hide_my_ip_test.dart` FAIL (switch initialized true) | clean (`diff -r` rc=0) |

---

## 5. Adversarial Cases Tried
1. **Passing both `--hide-ip` and `--port-map`:** CLI prioritizes `--hide-ip` and suppresses direct candidate emission.
2. **Flag negation attempt (`--no-hide-ip`):** Flag is declared `negatable: false`; attempting `--no-hide-ip` throws standard ArgParser usage error.
3. **Disclosure text formatting check:** Verifies no actual IP addresses, tokens, or URL fragments are printed in the disclosure lines.
4. **App Sheet Cancel / Re-open:** Verifies toggle resets cleanly and does not leak state across sheet presentations.
5. **Port range validation in docs:** Verifies ports 53330–53349 match the code constants in `DirectOriginServer`.

---

## 6. Resource and Failure Behaviour
- Pure CLI argument parsing and UI widget state; no background tasks or sockets allocated.
- Zero secrets or credentials in console outputs or widget text.

---

## 7. Compatibility
- Patch applies cleanly to tree + K0 + K1 + K2 + K3: `git apply --check -p1 docs/plans/inc5b-proposals/K4/patch.diff` (rc=0).
- Pure Dart and Flutter widget tests without native dependencies.

---

## 8. Verdict
**ACCEPT**

### What the final deep review must re-check:
- Ensure CLI help (`ls link --help`) displays the `--hide-ip` and `--port-map` descriptions accurately.
