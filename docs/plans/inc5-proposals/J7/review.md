# Review: Card J7 (Flutter App Link Sharing UI)

## 1. Scope
- Exact files changed/added:
  - `apps/libreshare_app/lib/platform/sleep_inhibitor.dart` (new file, `patch.diff` count: 4 files, `grep -c '^--- ' patch.diff` = 4)
  - `apps/libreshare_app/lib/services/deep_link_handler.dart` (new file)
  - `apps/libreshare_app/lib/widgets/create_link_sheet.dart` (new file)
  - `apps/libreshare_app/lib/widgets/receive_link_dialog.dart` (new file)
  - `apps/libreshare_app/test/widgets/link_share_ui_test.dart` (new test suite, 7 tests)
- Spec & plan rows satisfied:
  - `FR-14` (Off-LAN share link UI: CreateLinkSheet, ReceiveLinkDialog, DeepLinkHandler, SleepInhibitor)
  - `NFR-01` (Usability: first-use privacy consent, clear error states, copy button)
  - `docs/plans/inc5.md` Section 4 row App

## 2. Diff Read
- `sleep_inhibitor.dart` (`L1-60`): OK. System sleep prevention interface with `LinuxSleepInhibitor` (`systemd-inhibit`) and `NoopSleepInhibitor`. Safe acquire and release lifecycle.
- `deep_link_handler.dart` (`L1-55`): OK. **[SECURITY-CRITICAL: Deep Link Parsing]** Parses and validates `libreshare://r?...` and `https://.../r#...` deep links using `ShareLink.parse`. Handles scheme validation safely.
- `create_link_sheet.dart` (`L1-280`): OK. **[SECURITY-CRITICAL: Consent & Leak Prevention]** Modal bottom sheet. Presents Cloudflare Quick Tunnel privacy notice prior to hosting. Provides selectors for expiry (`15m`, `1h`, `24h`), receivers (`1`, `5`, `anyone`), and "Hide My IP Address". Acquires `SleepInhibitor` on start and guarantees release in `dispose()`.
- `receive_link_dialog.dart` (`L1-190`): OK. **[SECURITY-CRITICAL: Link Validation & SSRF]** Input dialog with clipboard paste. Validates link syntax and displays localized error texts on rejected links. Progress indicator during download.

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Power management | `acquires and releases sleep inhibitor state cleanly` | Sleep inhibitor acquires lock on start and releases unconditionally on stop/dispose. |
| Deep link parsing | `parses libreshare://r deep link into ShareLink` | Parses custom scheme URI into valid typed `ShareLink` object. |
| Deep link rejection | `rejects invalid scheme or malformed deep link` | Rejects malformed links with user-facing error message. |
| Host sheet & consent | `shows consent card first, then allows configuring...` | Requires explicit user agreement to Cloudflare terms before proceeding. |
| Tunnel error reporting | `displays error text when tunnel creation fails` | Renders user-friendly failure message if tunnel provider fails. |
| Receiver validation | `shows input, validates link and reports error on invalid link` | Displays error indicator when invalid or expired link is entered. |
| Download progress | `shows progress indicator when valid link download begins` | Transitions to progress state upon initiating valid link transfer. |

All assertions contain active `expect` statements with exact matcher evaluation (zero empty tests, zero skips).

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| Privacy consent guard | Bypass consent requirement in `CreateLinkSheet` | `shows consent card first, then allows configuring` | rc=1 | `diff -r` clean, rc=0 |
| Sleep inhibitor release | Comment out `_inhibitor.release()` in `dispose()` | `acquires and releases sleep inhibitor state cleanly` | rc=1 | `diff -r` clean, rc=0 |
| Deep link scheme check | Allow arbitrary URI schemes in `DeepLinkHandler` | `rejects invalid scheme or malformed deep link` | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **Unmounting `CreateLinkSheet` while tunnel is active:** `dispose()` releases sleep inhibitor and terminates tunnel without leaking system resources.
2. **Pasting malformed/huge string into `ReceiveLinkDialog`:** Safely caught by `ShareLinkException` and displays error banner without crashing widget tree.
3. **Pasting internal IP literal link into dialog:** Displays SSRF rejection message to user.
4. **Tunnel creation failure:** Sheet remains mounted and displays clear retry prompt without crash.
5. **Double-tapping "Create Link" button:** Disabled during asynchronous tunnel initialization to prevent duplicate tunnel spawns.

## 6. Resource and Failure Behaviour
- Sleep inhibitor lock: strictly acquired on start and unconditionally released on cancel, error, or unmount.
- Widget controllers: `TextEditingController` disposed cleanly.
- Secret redaction: root keys and tokens never rendered in diagnostic logs or error dialogs.

## 7. Compatibility
- `patch -p1 --dry-run < docs/plans/inc5-proposals/J7/patch.diff`:
  `rc=0` (clean application against current repository tree).
- `dart analyze --fatal-infos apps/libreshare_app/lib/platform/sleep_inhibitor.dart apps/libreshare_app/lib/services/deep_link_handler.dart apps/libreshare_app/lib/widgets/create_link_sheet.dart apps/libreshare_app/lib/widgets/receive_link_dialog.dart`:
  `rc=0` (0 errors, 0 warnings, 0 infos).
- `dart format --output=none --set-exit-if-changed ...`:
  `rc=0` (0 files changed).
- Existing test suites remain green.

## 8. Verdict
**ACCEPT**
What the final deep review must re-check:
- Ensure UI strings match internationalization tables in `l10n_strings.dart`.
