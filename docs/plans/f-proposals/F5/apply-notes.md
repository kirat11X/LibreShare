# Card F5 (U4 Windows Secure Key Store) Apply Notes

## 1. Requested Package Dependency: `win32`

To activate the reference Windows DPAPI secret store (`dpapi_secret_store_windows.dart.txt` -> `dpapi_secret_store_windows.dart`), the orchestrator is requested to add `win32` to `apps/libreshare_app/pubspec.yaml`:

```yaml
dependencies:
  win32: ^5.5.0
```

### License & Compliance Audit
- **Package**: `win32` (Dart / Windows FFI bindings by Tim Sneath)
- **License**: BSD-3-Clause (permissive, royalty-free, fully compatible with LibreShare's MIT license).
- **Target OS**: Windows only. In Flutter/Dart, FFI libraries are linked conditionally; on non-Windows platforms, DPAPI classes are omitted or guarded by `Platform.isWindows`.
- **Licence Register**: An entry should be added to `docs/dev/licences.md` under Section 7 (Dependencies).

---

## 2. File Placement & Integration

The patch (`patch.diff`) introduces:
1. `apps/libreshare_app/lib/platform/secret/migrating_secret_store.dart`: Platform-agnostic migration logic, store selector (`createPlatformSecretStore`), verified read-back guarantee, and identity loss invariant preservation.
2. `apps/libreshare_app/test/secret_store_windows_test.dart`: 14 comprehensive unit tests verifying migration, verified read-back, corrupt blob handling with `CredentialStore`, zero secret logging, and disk interactions.

When `win32` is activated:
3. Move `docs/plans/f-proposals/F5/dpapi_secret_store_windows.dart.txt` to `apps/libreshare_app/lib/platform/secret/dpapi_secret_store_windows.dart`.
4. In `apps/libreshare_app/lib/platform/platform_factory.dart` or `engine_provider.dart`, wire:
   ```dart
   final secretStore = createPlatformSecretStore(
     directory: securityDir,
     protectedStore: Platform.isWindows ? DpapiSecretStore(dpapiDir) : null,
   );
   ```

---

## 3. Windows Manual Verification Protocol

Because Windows DPAPI relies on OS-level cryptographic functions (`CryptProtectData`, `CryptUnprotectData` in `Crypt32.dll`) tied to Windows user credentials, full end-to-end OS verification must be conducted on a Windows host or CI runner:

### Verification Steps on Windows 10/11:
1. **Compilation Check**:
   ```cmd
   flutter build windows --debug
   ```
   Ensure build succeeds with zero FFI / C symbol link errors.

2. **Automated Unit Suite**:
   ```cmd
   flutter test test/secret_store_windows_test.dart
   ```
   Ensure all 14 tests pass cleanly.

3. **Migration Protocol from Legacy File Store**:
   - Create legacy test files in `%APPDATA%\dev.libreshare.libreshare_app\security\`:
     - `identity.key` (or corresponding sha256 `.secret` file)
     - `app-pin`
   - Launch the application:
     - The app executes `MigratingSecretStore.get()` during credential loading.
     - Inspect `%APPDATA%\dev.libreshare.libreshare_app\security_dpapi\`: verify `.dpapi` files are created.
     - Inspect `%APPDATA%\dev.libreshare.libreshare_app\security\`: verify legacy `.secret` files are deleted after verified read-back.
     - Verify device fingerprint matches the original key (no `IdentityLostException`, no `KEY_CHANGED`).

4. **Corrupted Blob / Identity Protection Verification**:
   - Close the app.
   - Open any `.dpapi` file in a hex editor and corrupt bytes (e.g. flip several bytes in the middle of ciphertext).
   - Relaunch the app:
     - Verify that `CryptUnprotectData` returns error code (`NTE_BAD_DATA` / `0x80090005` or `ERROR_INVALID_DATA`).
     - Verify `MigratingSecretStore` throws `SecretStoreException`.
     - Verify `CredentialStore` catches the unreadable key and throws `IdentityLostException`.
     - **CRITICAL INVARIANT**: Verify the app does NOT regenerate a new device ID or overwrite the corrupted key. The user should see the identity recovery screen.
