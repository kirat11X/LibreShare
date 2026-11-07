# Card K1 Verifier & Mutation Report

**Verifier:** Independent Verifier  
**Target:** Card K1 ("Not Enough Free Space" Phone Error)  
**Status:** VERIFIED (4/4 mutations killed, 0 survivors)

## 1. Mutation Test Table

| Mutation ID | Target File | Mutation Description | Test Expected to Fail | Result |
|---|---|---|---|---|
| **M1** | `file_sender.dart` | Remove `folder` message check; map all 507 to `diskFull` | `k1_storage_unusable_test.dart` (lines 118, 131) | **KILLED** (Failed as expected) |
| **M2** | `file_sender.dart` | Map all 507 unconditionally to `storageUnusable` | `k1_storage_unusable_test.dart` (lines 144, 157) | **KILLED** (Failed as expected) |
| **M3** | `settings_screen.dart` | Omit `_isFolderWritable` check; always update downloadDir | `k1_folder_unusable_test.dart` (line 154) | **KILLED** (Failed as expected) |
| **M4** | `settings_screen.dart` | Omit error `SnackBar` display when directory is unwritable | `k1_folder_unusable_test.dart` (line 157) | **KILLED** (Failed as expected) |

## 2. Gate Verification Evidence

- `packages/libreshare_core/test/unit/k1_storage_unusable_test.dart`: 5/5 PASSED (rc=0)
- `packages/libreshare_core/test/unit/send_result_refusal_test.dart`: 16/16 PASSED (rc=0)
- `apps/libreshare_app/test/k1_folder_unusable_test.dart`: 4/4 PASSED (rc=0)
- `apps/libreshare_app/test/settings_screen_test.dart`: 38/38 PASSED (rc=0)
- `apps/libreshare_app/test/transfer_screen_test.dart`: 21/21 PASSED (rc=0)
- `dart analyze packages/libreshare_core/lib apps/libreshare_app/lib`: 0 issues found (rc=0)
- `dart format --output=none --set-exit-if-changed`: 0 differences (rc=0)
