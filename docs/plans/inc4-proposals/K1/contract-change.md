# Contract Change Proposal: Card K1 ("Not Enough Free Space" Phone Error)

## Problem Statement
When a receiving device's download folder is not usable (e.g. read-only filesystem, missing Android storage permissions, unwritable destination), the receiver's `_checkDownloadDir()` in `FileReceiver` throws `LsException(LsErrorCode.insufficientStorage, 'download folder is not usable')` (HTTP 507).

Currently, `FileSender._failureFromException` maps all `LsErrorCode.insufficientStorage` exceptions unconditionally to `FailureReason.diskFull`:
```dart
LsErrorCode.insufficientStorage => _SendFailure(
  FailureReason.diskFull,
  detail,
  notifyPeer: true,
),
```
In the app UI, `FailureReason.diskFull` renders:
> *"There is not enough free space on the receiving device."*

On mobile devices (Android), users with gigabytes of free storage are confused by this error message when the real issue is an unwritable or restricted directory. Furthermore, the settings screen currently allows selecting an unwritable directory without immediate validation.

---

## Proposed Contract Changes

### 1. `packages/libreshare_core/lib/src/model/transfer_status.dart`
Add `storageUnusable` to `enum FailureReason`:
```dart
enum FailureReason {
  rejected('REJECTED'),
  timeout('TIMEOUT'),
  cancelled('CANCELLED'),
  verifyFailed('VERIFY_FAILED'),
  noConnection('NO_CONNECTION'),
  diskFull('DISK_FULL'),
  storageUnusable('STORAGE_UNUSABLE'),
  protocolError('PROTOCOL_ERROR');

  const FailureReason(this.wire);
  final String wire;
  static FailureReason? fromWire(String? w) =>
      w == null ? null : FailureReason.values.firstWhere((r) => r.wire == w);
}
```

### 2. `packages/libreshare_core/lib/src/transfer/file_sender.dart`
Differentiate the 507 message:
```dart
LsErrorCode.insufficientStorage => _SendFailure(
  e.message.toLowerCase().contains('folder')
      ? FailureReason.storageUnusable
      : FailureReason.diskFull,
  detail,
  notifyPeer: true,
),
```

### 3. `apps/libreshare_app/lib/l10n_strings.dart` & `apps/libreshare_app/lib/screens/transfer_screen.dart`
- In `l10n_strings.dart`:
  ```dart
  'failure.storageUnusable': 'The download folder on the receiving device is not usable or unwritable.',
  'settings.folderUnwritable': 'The selected folder cannot be written to. Please choose another location.',
  ```
- In `transfer_screen.dart`:
  ```dart
  FailureReason.diskFull => tr('failure.diskFull'),
  FailureReason.storageUnusable => tr('failure.storageUnusable'),
  ```

### 4. `apps/libreshare_app/lib/screens/settings_screen.dart`
Validate directory writability upon selection before updating settings:
```dart
onTap: () async {
  if (busy()) return;
  final picked = await ref.read(filePickerServiceProvider).pickDirectory();
  if (picked != null) {
    if (!isFolderWritable(picked)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('settings.folderUnwritable'))),
      );
      return;
    }
    await ref.read(settingsProvider.notifier).setDownloadDir(picked);
  }
}
```
where `isFolderWritable(Directory dir)` creates and immediately deletes a temporary probe file (`.lsprobe-*`).
