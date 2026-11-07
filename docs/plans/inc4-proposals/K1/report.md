# Card K1 Implementation Report ("Not Enough Free Space" Phone Error)

**Card:** K1  
**Status:** PASSED (All tests green, 0 analyze errors, 0 format differences, 4/4 mutations killed)

## 1. Problem Statement & Root Cause
When an Android device's download folder is not usable (due to missing storage permissions, restricted Scoped Storage paths, or read-only filesystems), the receiving device responds with HTTP 507 (`LsErrorCode.insufficientStorage`, `'download folder is not usable'`).

Previously, `FileSender._classifyWire` unconditionally mapped all 507 responses to `FailureReason.diskFull`. In the UI, this was presented as:
> *"There is not enough free space on the receiving device."*

This caused significant confusion on mobile devices where dozens of gigabytes of free flash space were present. In addition, the settings screen allowed selecting an unwritable destination folder without validating write permissions up front.

## 2. Changes Made
1. **Model (`transfer_status.dart`):**
   - Added `storageUnusable('STORAGE_UNUSABLE')` to `enum FailureReason`.
   - Preserved bidirectional wire conversion via `fromWire`.
2. **Transfer Logic (`file_sender.dart`):**
   - In `_classifyWire`: inspected `e.message` on 507 responses. If the message indicates a folder issue (`contains('folder')`), mapped to `FailureReason.storageUnusable`; otherwise retained `FailureReason.diskFull`.
3. **Localization (`l10n_strings.dart`):**
   - Added `'failure.storageUnusable'`: `"The download folder on the receiving device is not usable or unwritable."`
   - Added `'settings.folderUnwritable'`: `"The selected folder cannot be written to. Please choose another location."`
4. **App Screens (`transfer_screen.dart` & `settings_screen.dart`):**
   - `transfer_screen.dart`: mapped `FailureReason.storageUnusable => tr('failure.storageUnusable')`.
   - `settings_screen.dart`: added `_isFolderWritable` probe creating and deleting a temporary probe file (`.lsprobe-*`). When an unwritable directory is picked, settings displays an error SnackBar and does NOT update the download directory. When a writable directory is picked, settings updates normally.

## 3. Test Suites Delivered
- `k1_storage_unusable_test.dart`: Core unit tests covering enum wire round-trip and sender classification during session creation and chunk uploads.
- `k1_folder_unusable_test.dart`: App widget tests covering `failureText`, `TransferScreen`, and `SettingsScreen` folder picking with unwritable and writable directories.
