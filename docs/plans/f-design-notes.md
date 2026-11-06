# Module F Design Notes (Wave 2: Usable Every Day)

Prepared by Lead (Antigravity) according to `MODULE_F_PROMPT.md` and user instructions.
Delivered as patches in `.toolchain/scratch/f-chain/clone`, never applied directly to the real tree.

---

## F1 = U3 QR Pairing Screen + Visibility Selector + Contacts

### Target Files in Clone
- `apps/libreshare_app/lib/screens/pair_screen.dart` (new)
- `apps/libreshare_app/lib/widgets/receive_card.dart` (update visibility selector)
- `apps/libreshare_app/lib/screens/home_screen.dart` (pair button / routing)
- `apps/libreshare_app/lib/screens/settings_screen.dart` (pair entry point)
- `apps/libreshare_app/lib/l10n_strings.dart` (strings)
- `apps/libreshare_app/lib/providers/router_provider.dart` (route `/pair`)

### UI Strings (`l10n_strings.dart`)
- `'pair.title'`: `'Pair device'`
- `'pair.inviteHeading'`: `'Pairing invite'`
- `'pair.inviteHelp'`: `'Scan this QR code from another device, or copy the invite link.'`
- `'pair.copyLink'`: `'Copy invite'`
- `'pair.linkCopied'`: `'Invite link copied'`
- `'pair.pastePrompt'`: `'Or paste an invite from another device'`
- `'pair.pasteField'`: `'libreshare://pair?...'`
- `'pair.redeem'`: `'Pair'`
- `'pair.expires'`: `'Expires in {time}'`
- `'pair.expired'`: `'This pairing invite has expired.'`
- `'pair.used'`: `'This invite was already used.'`
- `'pair.declined'`: `'Pairing request was declined.'`
- `'pair.success'`: `'Paired with {alias}'`
- `'visibility.title'`: `'Who can see this device'`
- `'visibility.everyone'`: `'Everyone'`
- `'visibility.contacts'`: `'Contacts only'`
- `'visibility.nobody'`: `'Nobody'`
- `'visibility.contactsHelp'`: `'Only devices in your contacts can see this device and send files.'`

### Key Mapping (`Key(...)`)
- `pair-screen`
- `pair-qr-display`
- `pair-copy-button`
- `pair-paste-field`
- `pair-redeem-button`
- `pair-status-message`
- `visibility-selector`
- `visibility-segment-everyone`
- `visibility-segment-contacts`
- `visibility-segment-nobody`

### Acceptance Tests
- `apps/libreshare_app/test/u3_pairing_test.dart`
  - Engine A creates invite, Engine B redeems -> both add each other to contacts list.
  - Expired invite rejected with user-visible message.
  - Replayed / reused invite rejected.
  - The secret token `s=` never appears in logs, debug strings, or semantics.
- `apps/libreshare_app/test/u3_visibility_test.dart`
  - Engine A with `ReceiveVisibility.contacts`: Engine B (contact) can see and send.
  - Engine C (stranger): `GET /info` returns 404, not discovered.
  - Engine A with `ReceiveVisibility.nobody`: invisible to everyone.

---

## F2 = U5 UX Leftovers

### Target Files in Clone
- `apps/libreshare_app/lib/widgets/empty_state.dart`
- `apps/libreshare_app/lib/screens/home_screen.dart`
- `apps/libreshare_app/lib/screens/settings_screen.dart`
- `apps/libreshare_app/lib/l10n_strings.dart`

### Features
- Banner on `HomeScreen`: "Receiving only while LibreShare is open" when Receive is On and background execution is not supported/active.
- Battery-saver guidance in Settings: Android instructions for background power restrictions.
- Windows toast notification opt-in setting (boolean preference in `AppSettingsStore`, no external package).

### Acceptance Tests
- `apps/libreshare_app/test/u5_ux_leftovers_test.dart`
  - Banner shows when receiving and hides when off.
  - Settings persistence for Windows toast preference.
  - Overflow checks at 360x640 with textScaler 1.3.

---

## F3 = U2 Notifications (Logic & Seam Only)

### Target Files in Clone
- `apps/libreshare_app/lib/platform/notifications/notification_service.dart` (abstract interface + `NoOpNotificationService`)
- `apps/libreshare_app/lib/providers/notification_provider.dart` (Riverpod provider listening to engine transfer events)
- `apps/libreshare_app/test/notifications_test.dart` (tests using `FakeNotificationService`)

### Constraints
- Zero modifications to `pubspec.yaml` (dependency request documented in `apply-notes.md`).
- Notification contains Accept and Reject actions that route through `transfersProvider` using exact session IDs.
- Never puts PIN, full fingerprint, or sensitive path into notification payload.

---

## F4 = U1 Android Background Receive Service

### Target Files in Clone
- `apps/libreshare_app/lib/platform/android/receive_host.dart`
- `apps/libreshare_app/test/p9_receive_service_test.dart`
- `apps/libreshare_app/android/app/src/main/kotlin/dev/libreshare/libreshare_app/ReceiveService.kt`
- `apps/libreshare_app/android/app/src/main/kotlin/dev/libreshare/libreshare_app/ReceiveTileService.kt`
- `apps/libreshare_app/android/app/src/main/kotlin/dev/libreshare/libreshare_app/ReceiveResumeActivity.kt`
- `apps/libreshare_app/android/app/src/main/AndroidManifest.xml` (patch only)

### Manifest Security Rules
- Every new component marked `android:exported="false"`, except `ReceiveTileService` which requires `android.permission.BIND_QUICK_SETTINGS_TILE`.
- No `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.
- Preserve `usesCleartextTraffic`.

---

## F5 = U4 Windows Secure Key Store (Logic Only)

### Target Files in Clone
- `apps/libreshare_app/lib/platform/secret/migrating_secret_store.dart`
- `apps/libreshare_app/test/secret_store_windows_test.dart`
- `docs/plans/f-proposals/F5/dpapi_secret_store_windows.dart.txt` (reference binding without adding win32 dependency)

### Security Invariants
- Corrupted protected blob returns an error and never regenerates identity.
- Old plaintext store is only deleted after read-back verification succeeds.
