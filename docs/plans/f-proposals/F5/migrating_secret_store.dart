import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:logging/logging.dart';

final Logger _log = Logger('libreshare.platform.secret.migration');

/// A [SecretStore] that safely migrates secrets from an [oldStore] (e.g. legacy
/// plaintext or POSIX [FileSecretStore]) to a [newStore] (e.g. Windows DPAPI-protected store).
///
/// Security & Migration Invariants:
/// 1. Reads query [newStore] first. If [newStore] has no entry, it falls back to [oldStore].
/// 2. If [newStore] encounters a corrupted blob or unprotect failure, it throws [SecretStoreException],
///    which is propagated immediately and NEVER caught or suppressed. This ensures callers like
///    `CredentialStore` fail with `IdentityLostException` instead of regenerating identity.
/// 3. When migrating from [oldStore] or writing via [put], the secret is written to [newStore]
///    and immediately verified via a read-back check.
/// 4. An entry in [oldStore] is deleted ONLY after the read-back from [newStore] succeeds and
///    is verified to be byte-identical to the source value.
/// 5. If read-back fails, mismatches, or throws, [oldStore] is preserved untouched.
/// 6. No secret names or secret bytes are ever logged or included in exception messages.
class MigratingSecretStore implements SecretStore {
  MigratingSecretStore({required this.oldStore, required this.newStore});

  /// The legacy store (e.g. [FileSecretStore]).
  final SecretStore oldStore;

  /// The target protected store (e.g. DPAPI store).
  final SecretStore newStore;

  @override
  Future<Uint8List?> get(String key) async {
    // 1. Query newStore first.
    // If newStore throws (e.g. corrupt blob), allow the exception to propagate
    // directly so identity loss is properly handled without regenerating keys.
    final newBytes = await newStore.get(key);
    if (newBytes != null) {
      return newBytes;
    }

    // 2. If absent in newStore, check oldStore.
    final oldBytes = await oldStore.get(key);
    if (oldBytes == null) {
      return null;
    }

    // 3. Secret found in oldStore: attempt verified migration to newStore.
    try {
      await _migrateEntry(key, oldBytes);
    } on Object catch (e) {
      // If migration fails (e.g. disk full, read-back failure), log high-level warning.
      // Crucially, oldStore was NOT deleted.
      _log.warning(
        'Migration of secret to protected store failed: ${e.runtimeType}',
      );
    }

    return oldBytes;
  }

  @override
  Future<void> put(String key, Uint8List value) async {
    // 1. Write to newStore.
    await newStore.put(key, value);

    // 2. Verified read-back from newStore.
    final readBack = await newStore.get(key);
    if (readBack == null || !_bytesEqual(readBack, value)) {
      throw const SecretStoreException('verified read-back failed after write');
    }

    // 3. Delete from oldStore ONLY after verified read-back succeeds.
    try {
      await oldStore.delete(key);
    } on Object catch (e) {
      _log.warning(
        'Could not delete old secret after successful write: ${e.runtimeType}',
      );
    }
  }

  @override
  Future<void> delete(String key) async {
    // Delete from both stores to ensure the secret is completely purged.
    await newStore.delete(key);
    await oldStore.delete(key);
  }

  /// Explicitly migrates [key] from [oldStore] to [newStore].
  ///
  /// Returns `true` if migrated, or `false` if [key] was not in [oldStore].
  /// Throws [SecretStoreException] if write or verified read-back fails,
  /// guaranteeing [oldStore] is untouched on failure.
  Future<bool> migrateKey(String key) async {
    final oldBytes = await oldStore.get(key);
    if (oldBytes == null) {
      return false;
    }
    await _migrateEntry(key, oldBytes);
    return true;
  }

  Future<void> _migrateEntry(String key, Uint8List oldBytes) async {
    // Write to newStore
    await newStore.put(key, oldBytes);

    // Verified read-back
    final readBack = await newStore.get(key);
    if (readBack == null || !_bytesEqual(readBack, oldBytes)) {
      throw const SecretStoreException(
        'verified read-back failed during migration',
      );
    }

    // ONLY delete old entry after verified read-back succeeds!
    await oldStore.delete(key);
    _log.info('Successfully migrated secret to protected store');
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// Factory for selecting or building the appropriate platform secret store.
///
/// On Windows, if [protectedStore] is provided (e.g. DpapiSecretStore), returns
/// a [MigratingSecretStore] that safely migrates from [FileSecretStore] to [protectedStore].
/// Otherwise, returns a standard [FileSecretStore].
SecretStore createPlatformSecretStore({
  required Directory directory,
  SecretStore? protectedStore,
}) {
  final fileStore = FileSecretStore(directory);
  if (protectedStore != null) {
    return MigratingSecretStore(oldStore: fileStore, newStore: protectedStore);
  }
  return fileStore;
}
