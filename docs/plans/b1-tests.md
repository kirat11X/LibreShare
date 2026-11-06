# B1 tests (hand-over, tester -> coder)

All files under `apps/libreshare_app/test/`:
- `b1_incoming_security_test.dart`
- `b1_sender_security_test.dart`
- `b1_settings_security_test.dart`

Validated against the current LibreShare codebase. Every test file was executed 3 times consecutively; test outcomes and failure modes are deterministic.

## Files and groups
| File | Group |
|---|---|
| `b1_incoming_security_test.dart` | Incoming transfer dialog - SAS verification code: positive twin (shows heading, grouped 6 digits `123 456`, comparison instruction, enables Accept when code arrives), negative twin (when sasRequired true and sasCode null, Accept disabled until code arrives), negative twin (when sasRequired false, heading absent and Accept enabled immediately) |
| `b1_incoming_security_test.dart` | Incoming transfer dialog - PeerTrust badge: positive twin ("New device" on PeerTrust.unknown, "Known device" on PeerTrust.known, "Trusted contact" on PeerTrust.trusted) |
| `b1_incoming_security_test.dart` | Incoming transfer dialog - Key changed red banner: positive twin (red banner "This device's security key changed. It may be a new phone, or someone pretending to be it.", NO Accept button, link to Contacts), negative twin (keyChanged false -> no banner, Accept button present) |
| `b1_incoming_security_test.dart` | Incoming transfer dialog - RenderFlex check: mobile viewport 360x640 with 1.3x text scale renders cleanly without RenderFlex overflow |
| `b1_sender_security_test.dart` | Sender transfer screen - SAS verification display: positive twin (displays formatted 6 digits `123 456` and "Compare this code with the receiver's screen"), negative twin (when sasCode null, verification block absent) |
| `b1_sender_security_test.dart` | Sender transfer screen - Key-changed warning: positive twin (keyChanged true shows red warning banner "Security key changed"), negative twin (keyChanged false shows normal transfer state) |
| `b1_sender_security_test.dart` | Sender transfer screen - Insecure peer indicator: positive twin (insecurePeer true shows plaintext security warning banner/chip), negative twin (insecurePeer false shows standard secure transfer view) |
| `b1_sender_security_test.dart` | Sender transfer screen - PIN prompt: positive twin (pinRequired true prompts sender for 6-digit PIN input), negative twin (pinRequired false shows standard transfer view without PIN prompt) |
| `b1_sender_security_test.dart` | Sender transfer screen - Refusal reason mapping: positive twin (maps LsErrorCode refusal codes like declined, blockedPeer, invalidPin to human-readable strings without raw codes or hex) |
| `b1_sender_security_test.dart` | Sender transfer screen - RenderFlex check: mobile viewport 360x640 with 1.3x text scale renders cleanly without RenderFlex overflow |
| `b1_settings_security_test.dart` | Settings screen - Your fingerprint: positive twin (shows 16 hex in groups of 4 with a copy button, replacing the placeholder text), negative twin (when fingerprint is empty, placeholder is shown and copy button is absent) |
| `b1_settings_security_test.dart` | Settings screen - PIN selector: positive twin (PIN selector shows Off / Fixed / New each time; Fixed mode prompts for 6 digits and never reveals it after saving), negative twin (when PIN is Off, no PIN input field is shown) |
| `b1_settings_security_test.dart` | Settings screen - Contacts list: positive twin (displays contacts with alias, fingerprint, trust level text, and remove/block buttons), negative twin (empty contacts list shows empty indicator) |
| `b1_settings_security_test.dart` | Settings screen - RenderFlex check: mobile viewport 360x640 with 1.3x text scale renders cleanly without RenderFlex overflow |

## New symbols (minimal signatures)
- `providers/transfers_provider.dart`:
  - `TransferView` class parameters:
    ```dart
    const TransferView({
      ...
      String? sasCode,
      bool keyChanged = false,
      bool insecurePeer = false,
      LsErrorCode? refusal,
      bool pinRequired = false,
    });
    ```
  - `TransferView.copyWith` must also support `sasCode`, `keyChanged`, `insecurePeer`, `refusal`, and `pinRequired`.
- `widgets/incoming_transfer_dialog.dart`:
  - SAS code block: header text `Verification code`, formatted digits (e.g. `123 456`), instruction text `Compare with sender's screen`.
  - Accept button gating: `Accept` button must be disabled when `session.sasRequired && session.sasCode == null`.
  - PeerTrust badges: `New device` (`PeerTrust.unknown`), `Known device` (`PeerTrust.known`), `Trusted contact` (`PeerTrust.trusted`).
  - Key changed banner: red warning text `"This device's security key changed. It may be a new phone, or someone pretending to be it."` with no Accept button and a button/link `Open Contacts` (or navigating to Settings/Contacts).
- `screens/transfer_screen.dart`:
  - Verification code card/block: Key `Key('sender-sas-code-block')` or text `Verification code` + `123 456` + instruction `Compare this code with the receiver's screen`.
  - Key changed banner: Key `Key('sender-key-changed-banner')` or text `Security key changed`.
  - Insecure peer indicator: Key `Key('sender-insecure-peer-warning')` or text `Unencrypted connection`.
  - PIN prompt: Key `Key('sender-pin-input-field')` or PIN dialog/prompt when `pinRequired == true`.
  - Refusal reason text: mapping `LsErrorCode` (e.g. `LsErrorCode.declined`, `LsErrorCode.blockedPeer`, `LsErrorCode.invalidPin`) to human-readable strings (e.g. "Receiver declined the transfer", "You are blocked by this device", "Incorrect PIN entered").
- `screens/settings_screen.dart`:
  - Your fingerprint section: displays formatted 16 hex in 4 groups of 4 (`A1B2 C3D4 E5F6 0718`) and an `IconButton` / copy button with Key `Key('settings-copy-fingerprint-button')` or tooltip `Copy fingerprint`.
  - PIN mode selector: Key `Key('settings-pin-selector')` (dropdown / segmented button with `Off`, `Fixed`, `New each time`). In `Fixed`, displays Key `Key('settings-pin-input')` (6 digits) and Key `Key('settings-pin-save')`. Saved PIN is never displayed in plaintext.
  - Known Contacts list: Key `Key('settings-contacts-list')`. For each contact: alias, short fingerprint (`A1B2 C3D4`), trust level (`Verified` / `New` / `Changed` / `Blocked`), and action buttons `Remove` and `Block`. Empty state shows `No known contacts yet` / `No contacts`.
- Layout: All three screens (`IncomingTransferDialog`, `TransferScreen`, `SettingsScreen`) render cleanly at 360x640 mobile viewport with 1.3x text scale without `RenderFlex overflow`.

## Red state on the real tree
| File | State |
|---|---|
| `b1_incoming_security_test.dart` | Behavior red: +3 passed, -6 failed (exit code 1). Positive twins fail as expected on missing verification code, trust badges, key-changed banner; negative twins and 360x640 RenderFlex check pass. |
| `b1_sender_security_test.dart` | Compile error (exit code 1): `No named parameter with the name 'sasCode'` on `TransferView` in `lib/providers/transfers_provider.dart`. |
| `b1_settings_security_test.dart` | Behavior red: +2 passed, -5 failed (exit code 1). Positive twins fail as expected on placeholder fingerprint, missing PIN selector, missing contacts list; negative empty-fingerprint twin and 360x640 RenderFlex check pass. |

## SPEC-GAPs
1. `TransferView` in `lib/providers/transfers_provider.dart` currently lacks security metadata fields (`sasCode`, `keyChanged`, `insecurePeer`, `refusal`, `pinRequired`). Adding them is backwards-compatible because all have default values or nullability.
2. `IncomingTransferDialog` currently renders a generic trust indicator and has no SAS verification code block, key-changed warning banner, or Accept button disable condition.
3. `TransferScreen` currently only renders progress bar, speed, and failure reason; it lacks the sender-side SAS verification display, key-changed banner, unencrypted warning, and PIN entry dialog.
4. `SettingsScreen` currently has a placeholder string for fingerprint and lacks the interactive PIN mode selector and Known Contacts management list.
5. In `SettingsScreen`, `initialAppSettingsProvider` must be overridden in tests since `SettingsNotifier` watches it at startup.

## Recommended mutation checks
1. Incoming SAS code omitted from dialog UI -> SAS test fails.
2. Accept button remaining enabled while `sasRequired == true` and `sasCode == null` -> negative twin fails.
3. Omission of red banner when `keyChanged == true` -> key-changed test fails.
4. Accept button rendered when `keyChanged == true` -> key-changed test fails.
5. Plaintext PIN rendered after saving in Settings -> PIN privacy assertion fails.
6. Sender SAS code block rendered when `sasCode == null` -> sender negative twin fails.
7. Fixed PIN prompt missing in Settings -> PIN positive twin fails.
8. Unverified peer badge displayed as "Trusted contact" -> trust badge test fails.
