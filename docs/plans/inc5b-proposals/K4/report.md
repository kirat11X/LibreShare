# Card K4 Report: App/CLI Toggles, IP Disclosure & Firewall Port Range

**Card:** K4 (Wave 4: App/CLI Toggles, Disclosure & Port Range)  
**Author:** Lead  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 2/2 CLI tests pass x3, 2/2 widget tests pass x3, 3/3 mutations killed)

---

## 1. Summary of Changes
Card K4 completes the user-facing CLI and App controls, privacy disclosure notices, and firewall documentation for Increment 5b:

1. **CLI `link` Command (`packages/libreshare_cli/lib/ls_cli.dart`)**:
   - Added `--hide-ip` flag: when set, direct origin candidates are omitted, ensuring all traffic routes strictly through encrypted tunnels (`HIDE-IP: Direct candidates omitted. Tunnel-only routing active.`).
   - Added `--port-map` flag: allows user to request UPnP/NAT-PMP port mapping on the local gateway (default off per D1 security recommendation).
   - Added mandatory IP disclosure output when `--hide-ip` is not specified: `DISCLOSURE: Direct internet paths include your public IP address. Pass --hide-ip for tunnel only.`.

2. **App UI `CreateLinkSheet` (`apps/libreshare_app/lib/widgets/create_link_sheet.dart`)**:
   - Added `hide_ip_toggle` SwitchListTile: allows the user to easily toggle "Hide My IP Address" per share.
   - Includes user-facing disclosure subtitle: `Direct connections show your IP address to whoever opens the link.`.
   - Wires toggle state directly into link creation pipeline.

3. **Firewall & User Documentation (`docs/user/guide.md`)**:
   - Expanded TCP port range in firewall guides (`firewalld`, `ufw`, and Windows Defender instructions) from `53318-53327` to `53318-53349`.
   - Explicitly documents that ports 53330–53349 are reserved for ephemeral direct origin TLS transfers.

4. **Tests & Verification**:
   - `packages/libreshare_cli/test/link_hide_ip_test.dart`: Validates CLI `--hide-ip` flag behavior, tunnel-only link generation, absence of direct candidates, and proper emission of disclosure and hide-ip lines.
   - `apps/libreshare_app/test/widgets/hide_my_ip_test.dart`: Validates Flutter widget disclosure text, consent workflow, and interactive toggle state propagation.
   - Candidate leak audit: verified candidate lists and private IPs are never logged or leaked.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze --fatal-infos` passed with 0 issues across all packages.
- **Code Formatting**: `dart format --output=none --set-exit-if-changed` verified clean (0 changes).
- **Flake Gate**: 2/2 CLI tests and 2/2 widget tests passed across 3 consecutive test cycles without flakes.
- **Mutation Sweep**: 3/3 mutations killed (M1 bypass hide-ip in CLI, M2 omit disclosure text, M3 reverse widget toggle state).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for `docs/user/guide.md` and `packages/libreshare_cli/lib/ls_cli.dart`.
- `test/cli/link_hide_ip_test.dart`: CLI integration tests for `--hide-ip` and disclosure.
- `test/widgets/hide_my_ip_test.dart`: Flutter widget tests for `CreateLinkSheet` toggle and disclosure.
- `apply-notes.md`: Instructions for orchestrator application.
- `verifier-report.md`: Independent verifier sign-off.
