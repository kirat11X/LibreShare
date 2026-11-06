# D1 Tests: Wire App to Secure Engine and Make PIN Real

Created: 2026-11-06 (Wave D Card D1 Tester)
Author: Tester Subagent
Scope: `apps/libreshare_app/test/d1_*_test.dart`

## 1. Test Files and Groups

- **`apps/libreshare_app/test/d1_secure_engine_test.dart`**
  - Group `engineProvider - secure profile and identity`: asserts engine has `identity != null`, non-empty fingerprint, and caps `['sas', 'pair']`; contrasts with plaintext engine.
  - Group `engineProvider - identity persistence across restarts`: asserts identity persists under `<supportDir>/security` with identical fingerprint across restarts; distinct support dirs produce distinct identities.
  - Group `engineProvider - damaged or missing private key`: asserts intact security dir loads cleanly; damaged/missing key secret throws `IdentityLostException` without overwriting `identity.json`.
  - Group `engineProvider - insecure peer refusal`: asserts `allowInsecurePeers` is false by default, causing transfer to plaintext peer to fail with "uses an older version without encryption" message; secure peer does not fail with insecurePeer.

- **`apps/libreshare_app/test/d1_pin_persistence_test.dart`**
  - Group `PIN mode - Off vs Fixed and PIN persistence`: asserts default PIN mode Off has `enforced == false`; Fixed mode persists 6 digits to `FileSecretStore` as `app-pin`, sets `enforced == true`, survives restart, and never leaks into `app_settings.json` or `toString()`.
  - Group `PIN mode - New each time (Window policy)`: asserts window PIN is active while Receive is on, rotates on next window, and is displayed on Receive card; not displayed when Receive is Off.
  - Group `Fixed PIN input validation`: asserts 6 decimal digits are accepted and saved; 5 digits, letters, or mixed characters are rejected with a visible validation error and nothing is saved.

- **`apps/libreshare_app/test/d1_two_engine_pin_test.dart`**
  - Group `Two-engine secure PIN transfer and dialog flow`: asserts app sender against real secure receiver with PIN policy triggers `pinRequired`, sender-side PIN dialog displays, submitting correct PIN completes transfer, wrong PIN shows "That PIN was not accepted." without disclosing attempt count, and trusted contact is exempt from PIN.

---

## 2. New Symbols and Signatures (for Coder)

To make these tests pass, the coder needs to implement the following symbols and wiring in `apps/libreshare_app/lib/`:

### In `apps/libreshare_app/lib/services/app_settings_store.dart`:
```dart
// New field on AppSettings:
final PinMode pinMode;

// Constructor signature:
const AppSettings({
  required String deviceId,
  required String alias,
  String? downloadDir,
  int preferredPort = kDefaultPort,
  bool storageAsked = false,
  PinMode pinMode = PinMode.off,
});

// copyWith update:
AppSettings copyWith({
  String? alias,
  String? downloadDir,
  bool clearDownloadDir = false,
  int? preferredPort,
  bool? storageAsked,
  PinMode? pinMode,
});
```

### In `apps/libreshare_app/lib/providers/engine_provider.dart`:
```dart
// In EngineNotifier.build():
// Open security wiring under <supportDir>/security
final security = await SecurityWiring.open(
  directory: Directory(p.join(dirs.supportDir.path, 'security')),
  deviceId: identity.$1,
  pinPolicy: PinPolicy(mode: settings.pinMode),
  pin: fixedPin, // loaded from FileSecretStore(securityDir).get('app-pin') if pinMode == PinMode.fixed
  allowInsecurePeers: false,
);
ref.onDispose(() async {
  await _closeCurrent();
  await security.close();
});

// Pass to LibreShareEngine:
final engine = LibreShareEngine(
  ...
  security: security,
);
```

### In `apps/libreshare_app/lib/screens/settings_screen.dart`:
```dart
// Validation for 6 digits: RegExp(r'^[0-9]{6}$')
// On Save in Fixed mode: save PIN to FileSecretStore(securityDir).put('app-pin', utf8.encode(pin))
// Update AppSettings(pinMode: PinMode.fixed)
// On "New each time": update AppSettings(pinMode: PinMode.window)
// On "Off": update AppSettings(pinMode: PinMode.off)
```

### In `apps/libreshare_app/lib/widgets/receive_card.dart`:
```dart
// When receiving (state is On || state is Draining) and engine.pinGuard?.currentPin != null:
// Display active PIN on Receive card with key Key('receive-pin') or visible text
```

### In `apps/libreshare_app/lib/providers/transfers_provider.dart`:
```dart
// Map result?.refusal == LsErrorCode.pinRequired to pinRequired: true in _drive / _finish
// Handle PIN submission retry with engine.sendFiles(..., pin: pin) or engine.beginSendTo(..., pin: pin)
```

---

## 3. Red-State Results Table (Measured across 3 runs)

| # | Test File | Group | Test Description | Expected Result | Actual Result | Root Cause of Red State |
|---|---|---|---|---|---|---|
| 1 | `d1_secure_engine_test.dart` | secure profile and identity | positive twin: engine built by engineProvider has identity != null and non-empty fingerprint | `engine.identity != null`, `fingerprint != ''` | `Actual: <null>` | `engineProvider` does not pass `security:`, leaving engine in plaintext profile |
| 2 | `d1_secure_engine_test.dart` | identity persistence | positive twin: second build with same support dir has SAME fingerprint | `<supportDir>/security` exists, `fp2 == fp1` | `Expected: true, Actual: <false>` (security dir missing) | No `SecurityWiring.open` called under `<supportDir>/security` |
| 3 | `d1_secure_engine_test.dart` | identity persistence | negative twin: fresh support dir creates different identity | `fp1 != ''`, `fp2 != ''` | `Expected: non-empty, Actual: ''` | Fingerprints are empty because no identity is created |
| 4 | `d1_secure_engine_test.dart` | damaged or missing key | positive twin: intact security directory loads identity cleanly | `engine.identity != null` | `Actual: <null>` | Engine built without security wiring |
| 5 | `d1_secure_engine_test.dart` | damaged or missing key | negative twin: corrupt key causes IdentityLostException | throws `IdentityLostException` | `identity.json` missing | `SecurityWiring.open` not integrated into `engineProvider` |
| 6 | `d1_secure_engine_test.dart` | insecure peer refusal | positive twin: transfer to plaintext peer fails with older version message | `transfer.insecurePeer == true` | `Actual: <false>` | Engine defaults to plaintext and accepts plaintext peers |
| 7 | `d1_pin_persistence_test.dart` | Off vs Fixed PIN | negative twin: default PIN mode Off has enforced == false | `guard.enforced == false` | `guard` is `<null>` | `engine.pinGuard` is null because `security:` is null |
| 8 | `d1_pin_persistence_test.dart` | Off vs Fixed PIN | positive twin: Fixed mode saves PIN to FileSecretStore, survives restart, never leaks | `guard.enforced == true`, stored in secret store | `guard` is `<null>` | Settings Save does not persist to `FileSecretStore` and engine is not wired |
| 9 | `d1_pin_persistence_test.dart` | New each time (Window) | positive twin: window PIN active while Receive on, rotates, displayed on card | `guard.currentPin != null`, rotates | `guard` is `<null>` | Window PIN policy not wired and not rendered on Receive card |
| 10 | `d1_pin_persistence_test.dart` | Fixed PIN validation | negative twin: 5 digits rejected with visible error | error text visible, not saved | error text not found | `_pinController.text.length == 6` silently does nothing with no error text |
| 11 | `d1_pin_persistence_test.dart` | Fixed PIN validation | negative twin: letters rejected with visible error | error text visible, not saved | `PIN configured` displayed | Length check accepts any 6 characters including letters |
| 12 | `d1_two_engine_pin_test.dart` | Two-engine PIN transfer | positive twin: sender encounters pinRequired against real secure receiver | `transfer.pinRequired == true` | `Actual: <false>` | `_drive` does not set `pinRequired` from `LsErrorCode.pinRequired` |
| 13 | `d1_two_engine_pin_test.dart` | Two-engine PIN transfer | negative twin: wrong PIN causes refusal with pinInvalid | `failureReason == rejected`, `refusal == pinInvalid` | `Actual: FailureReason.noConnection` | Sender engine is plaintext, unable to perform TLS handshake with Bob |
| 14 | `d1_two_engine_pin_test.dart` | Two-engine PIN transfer | positive twin: trusted contact exempt from receiver PIN | transfer completes without PIN prompt | `Actual: <0>` (empty fingerprint) | Alice engine has no certificate fingerprint to pin in Bob's trust store |

---

## 4. Verification Runs

Command executed (under heavy lock, 3 consecutive runs):
```bash
source tools/env.sh && NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 flock -o /tmp/libreshare-heavy.lock flutter test --no-pub apps/libreshare_app/test/d1_*
```

- Run 1: `rc=1`, `00:04 +5 -14: Some tests failed.`
- Run 2: `rc=1`, `00:04 +5 -14: Some tests failed.`
- Run 3: `rc=1`, `00:04 +5 -14: Some tests failed.`

All 3 runs are completely deterministic with zero flakes.
