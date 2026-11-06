# Card F5 Proposal Report: Windows Secure Key Store & Migration

## 1. Summary of Work Delivered
Card F5 (U4) implements Windows secure key store migration logic and reference DPAPI bindings under `docs/plans/f-proposals/F5/`:
- `migrating_secret_store.dart`: Transparent, verified-read-back migration from legacy `FileSecretStore` to protected store.
- `secret_store_windows_test.dart`: 13 comprehensive unit tests covering migration paths, failure atomicity, and security invariants.
- `dpapi_secret_store_windows.dart.txt`: Reference DPAPI implementation via `package:win32` (`CryptProtectData`, `CryptUnprotectData`).
- `patch.diff`: Git-applicable unified diff targeting `apps/libreshare_app/`.
- `apply-notes.md`: Dependency request for `win32: ^5.5.0` (BSD-3-Clause) and Windows manual verification protocol.

## 2. Test Execution & Verification
- **Test Suite**: `secret_store_windows_test.dart`
- **Result**: `13/13 passed` (0 failed, 0 flakes, 0 skips, exit code 0).
- **Analyzer**: `HOME=/tmp dart analyze` on both delivered files -> `No issues found!` (rc=0).
- **Formatting**: `dart format --output=none --set-exit-if-changed` -> `0 changed` (rc=0).
- **Patch Application**: `patch -p1 --dry-run < patch.diff` -> Clean (rc=0).

## 3. Security Invariants
1. **Verified Read-Back Before Deletion**: An entry in `oldStore` is deleted strictly after verified read-back from `newStore` succeeds and matches byte-for-byte. If read-back fails (tampered bytes, null, or write error), `oldStore` is preserved untouched.
2. **Corrupted Protected Blob Handling**: If `newStore` contains a corrupted blob, `SecretStoreException` is thrown immediately and NEVER caught or suppressed. In `CredentialStore`, this triggers `IdentityLostException(keyUnreadable)` and NEVER regenerates the device identity.
3. **Zero Secret Logging**: Secret names and secret values are never logged or exposed in exception messages.

## 4. Mutation Audit
| Mutation | Target Location | Expected Failure | Actual Result |
|---|---|---|---|
| M1: Delete old store before verified read-back | `_migrateEntry` | Old entry lost on failed read-back | **KILLED** (3 tests RED) |
| M2: Catch & swallow corrupted blob / fallback | `get()` | Identity regenerated or error hidden | **KILLED** (test RED) |
| M3: Skip payload comparison in read-back | `_migrateEntry` | Corrupted write deletes old store | **KILLED** (test RED) |
| M4: Omit read-back check in `put()` | `put()` | Write failure deletes old store | **KILLED** (test RED) |
| M5: Leak secret key/payload in logs | `_migrateEntry` | Secret exposure in logs | **KILLED** (test RED) |
