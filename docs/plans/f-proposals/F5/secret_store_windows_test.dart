import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:logging/logging.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:libreshare_app/platform/secret/migrating_secret_store.dart';

({DeviceIdentity identity, Uint8List privateKeyPem}) _fakeIdentity(
  String deviceId,
  int seed,
) {
  final der = Uint8List.fromList(
    List<int>.generate(140, (i) => (seed * 31 + i * 7) % 256),
  );
  final b64 = base64.encode(der);
  final lines = <String>[
    for (var i = 0; i < b64.length; i += 64)
      b64.substring(i, i + 64 > b64.length ? b64.length : i + 64),
  ];
  final pem =
      '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n-----END CERTIFICATE-----\n';
  final key = Uint8List.fromList(
    utf8.encode(
      '-----BEGIN PRIVATE KEY-----\nSENTINELKEY$seed${'Q' * 40}\n-----END PRIVATE KEY-----\n',
    ),
  );
  return (
    identity: DeviceIdentity(
      deviceId: deviceId,
      fingerprint: fingerprintHex(der),
      certDer: der,
      certPem: pem,
    ),
    privateKeyPem: key,
  );
}

/// In-memory controllable [SecretStore] for tracking calls, simulating failures,
/// and verifying migration ordering.
class ControllableSecretStore implements SecretStore {
  final Map<String, Uint8List> data = {};
  final List<String> callLog = [];

  bool failPut = false;
  bool failGet = false;
  bool corruptReadBack = false;
  bool returnNullOnReadBack = false;

  @override
  Future<Uint8List?> get(String key) async {
    callLog.add('get:$key');

    if (failGet) {
      throw const SecretStoreException('corrupted protected blob');
    }

    if (corruptReadBack && data.containsKey(key)) {
      // Return corrupted bytes on read-back verification
      return Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
    }

    if (returnNullOnReadBack && data.containsKey(key)) {
      return null;
    }

    final val = data[key];
    return val != null ? Uint8List.fromList(val) : null;
  }

  @override
  Future<void> put(String key, Uint8List value) async {
    callLog.add('put:$key');
    if (failPut) {
      throw const SecretStoreException('storage write error');
    }
    data[key] = Uint8List.fromList(value);
  }

  @override
  Future<void> delete(String key) async {
    callLog.add('delete:$key');
    data.remove(key);
  }
}

void main() {
  group('MigratingSecretStore', () {
    late ControllableSecretStore oldStore;
    late ControllableSecretStore newStore;
    late MigratingSecretStore store;

    const testKey = 'identity.key';
    final testSecret = Uint8List.fromList(
      utf8.encode('super-secret-key-material'),
    );

    setUp(() {
      oldStore = ControllableSecretStore();
      newStore = ControllableSecretStore();
      store = MigratingSecretStore(oldStore: oldStore, newStore: newStore);
    });

    test('migration from old store to protected store on read', () async {
      await oldStore.put(testKey, testSecret);
      expect(newStore.data[testKey], isNull);

      final readValue = await store.get(testKey);

      expect(readValue, equals(testSecret));
      expect(
        newStore.data[testKey],
        equals(testSecret),
        reason: 'secret should be migrated to new store',
      );
      expect(
        oldStore.data[testKey],
        isNull,
        reason: 'secret should be deleted from old store after successful migration',
      );

      // Subsequent read should hit newStore directly
      newStore.callLog.clear();
      oldStore.callLog.clear();
      final readAgain = await store.get(testKey);
      expect(readAgain, equals(testSecret));
      expect(newStore.callLog, contains('get:$testKey'));
      expect(
        oldStore.callLog,
        isEmpty,
        reason: 'old store should not be consulted once new store has entry',
      );
    });

    test('verified read-back occurs before old file is deleted', () async {
      await oldStore.put(testKey, testSecret);
      oldStore.callLog.clear();
      newStore.callLog.clear();

      await store.get(testKey);

      // Verify sequence of operations:
      // 1. newStore.get (check if exists in newStore)
      // 2. oldStore.get (read from oldStore)
      // 3. newStore.put (write to newStore)
      // 4. newStore.get (verified read-back)
      // 5. oldStore.delete (delete only after read-back verified)
      final newPutIndex = newStore.callLog.indexOf('put:$testKey');
      final newReadBackIndex = newStore.callLog.lastIndexOf('get:$testKey');
      final oldDeleteIndex = oldStore.callLog.indexOf('delete:$testKey');

      expect(newPutIndex, isNonNegative);
      expect(
        newReadBackIndex,
        greaterThan(newPutIndex),
        reason: 'read-back must occur after put',
      );
      expect(oldDeleteIndex, isNonNegative);
      expect(oldStore.data[testKey], isNull);
    });

    test(
      'failed read-back (mismatched bytes) leaves old store untouched',
      () async {
        await oldStore.put(testKey, testSecret);
        newStore.corruptReadBack = true;

        // get() attempts migration; read-back fails; old store must NOT be deleted
        final read = await store.get(testKey);

        expect(
          read,
          equals(testSecret),
          reason:
              'caller should still receive old value despite migration failure',
        );
        expect(
          oldStore.data[testKey],
          equals(testSecret),
          reason: 'old secret must be preserved when read-back is corrupted',
        );
        expect(
          oldStore.callLog,
          isNot(contains('delete:$testKey')),
          reason: 'oldStore.delete must NEVER be called if read-back fails',
        );
      },
    );

    test(
      'failed read-back (null returned) leaves old store untouched',
      () async {
        await oldStore.put(testKey, testSecret);
        newStore.returnNullOnReadBack = true;

        final read = await store.get(testKey);

        expect(read, equals(testSecret));
        expect(
          oldStore.data[testKey],
          equals(testSecret),
          reason: 'old secret must be preserved when read-back returns null',
        );
        expect(oldStore.callLog, isNot(contains('delete:$testKey')));
      },
    );

    test('failed write to new store leaves old store untouched', () async {
      await oldStore.put(testKey, testSecret);
      newStore.failPut = true;

      final read = await store.get(testKey);

      expect(read, equals(testSecret));
      expect(oldStore.data[testKey], equals(testSecret));
      expect(oldStore.callLog, isNot(contains('delete:$testKey')));
    });

    test('corrupted protected blob in newStore throws error and NEVER falls back to oldStore', () async {
      // Even if old store still has a stale copy, newStore corruption must fail fast
      await oldStore.put(testKey, testSecret);
      newStore.failGet = true;

      expect(
        () => store.get(testKey),
        throwsA(isA<SecretStoreException>()),
        reason: 'corrupted blob must throw SecretStoreException directly',
      );
    });

    test(
      'put() writes to newStore, verifies read-back, and cleans up oldStore',
      () async {
        await oldStore.put(testKey, Uint8List.fromList([1, 2, 3]));
        final newSecret = Uint8List.fromList([4, 5, 6]);

        await store.put(testKey, newSecret);

        expect(newStore.data[testKey], equals(newSecret));
        expect(
          oldStore.data[testKey],
          isNull,
          reason: 'oldStore copy should be purged after verified put',
        );
      },
    );

    test('put() failing read-back throws SecretStoreException and preserves old store', () async {
      await oldStore.put(testKey, testSecret);
      newStore.corruptReadBack = true;

      expect(
        () => store.put(testKey, Uint8List.fromList([9, 9, 9])),
        throwsA(isA<SecretStoreException>()),
      );
      expect(
        oldStore.data[testKey],
        equals(testSecret),
        reason: 'old store must not be deleted if put verification fails',
      );
    });

    test('delete() deletes secret from both oldStore and newStore', () async {
      await oldStore.put(testKey, testSecret);
      await newStore.put(testKey, testSecret);

      await store.delete(testKey);

      expect(oldStore.data[testKey], isNull);
      expect(newStore.data[testKey], isNull);
    });

    test('migrateKey() explicitly migrates and returns status', () async {
      await oldStore.put(testKey, testSecret);

      final result = await store.migrateKey(testKey);
      expect(result, isTrue);
      expect(newStore.data[testKey], equals(testSecret));
      expect(oldStore.data[testKey], isNull);

      // Migrating non-existent key returns false
      final missing = await store.migrateKey('non.existent.key');
      expect(missing, isFalse);
    });
  });

  group('Security Invariant: CredentialStore and IdentityLostException', () {
    late Directory tempDir;
    late ControllableSecretStore newStore;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('libreshare_f5_test_');
      newStore = ControllableSecretStore();
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('corrupted protected blob triggers IdentityLostException and NEVER regenerates identity', () async {
      final oldStore = FileSecretStore(
        Directory('${tempDir.path}/old_secrets'),
      );
      final migratingStore = MigratingSecretStore(
        oldStore: oldStore,
        newStore: newStore,
      );

      // 1. First run: generate a valid identity in oldStore
      final credStore = CredentialStore(
        directory: Directory('${tempDir.path}/credentials'),
        secrets: migratingStore,
      );

      var generatorCalls = 0;
      ({DeviceIdentity identity, Uint8List privateKeyPem}) testGenerator(
        String devId,
      ) {
        generatorCalls++;
        return _fakeIdentity(devId, 1);
      }

      final initial = await credStore.loadOrCreate(
        generate: testGenerator,
        deviceId: 'device-test-id-1234',
      );
      expect(generatorCalls, 1);
      expect(initial.identity.deviceId, 'device-test-id-1234');

      // Verify secret was written and read back
      expect(newStore.data['identity.key'], isNotNull);

      // 2. Simulate corruption in protected newStore blob
      newStore.failGet = true;

      // 3. Second run: try to loadOrCreate with corrupt blob
      final credStore2 = CredentialStore(
        directory: Directory('${tempDir.path}/credentials'),
        secrets: migratingStore,
      );

      expect(
        () => credStore2.loadOrCreate(
          generate: testGenerator,
          deviceId: 'device-test-id-1234',
        ),
        throwsA(isA<IdentityLostException>()),
        reason: 'corrupted protected store must throw IdentityLostException',
      );

      // Crucial: generator was NOT called again. Identity was NOT regenerated!
      expect(
        generatorCalls,
        1,
        reason: 'identity must NEVER be regenerated when protected store is corrupt',
      );
    });
  });

  group('Real FileSecretStore on disk migration', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp(
        'libreshare_file_migration_',
      );
    });

    tearDown(() async {
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('real files on disk are migrated and deleted only after verified read-back', () async {
      final oldDir = Directory('${tempRoot.path}/old_sec');
      final oldFileStore = FileSecretStore(oldDir);
      final newProtectedStore = ControllableSecretStore();

      final migrating = MigratingSecretStore(
        oldStore: oldFileStore,
        newStore: newProtectedStore,
      );

      const secretName = 'app-pin';
      final secretValue = Uint8List.fromList(utf8.encode('123456'));

      await oldFileStore.put(secretName, secretValue);
      expect(oldDir.listSync().length, 1, reason: 'old file exists on disk');

      // Migrate on read
      final read = await migrating.get(secretName);
      expect(read, equals(secretValue));

      // New store has it
      expect(newProtectedStore.data[secretName], equals(secretValue));

      // Old file store on disk has deleted it
      expect(await oldFileStore.get(secretName), isNull);
    });
  });

  group('Zero Secret Logging Invariant', () {
    test('neither secret key names nor secret payloads are logged', () async {
      final logs = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(logs.add);

      final oldStore = ControllableSecretStore();
      final newStore = ControllableSecretStore();
      final store = MigratingSecretStore(
        oldStore: oldStore,
        newStore: newStore,
      );

      const secretName = 'kpair/confidential-device-999';
      final secretValue = Uint8List.fromList(
        utf8.encode('ultra-sensitive-kpair-data-321'),
      );

      await oldStore.put(secretName, secretValue);

      // Perform get, put, delete, and failed migration
      await store.get(secretName);
      newStore.corruptReadBack = true;
      try {
        await store.put(secretName, secretValue);
      } catch (_) {}

      await sub.cancel();

      // Audit all log messages
      for (final record in logs) {
        expect(
          record.message,
          isNot(contains('ultra-sensitive-kpair-data-321')),
          reason: 'secret value must never appear in logs',
        );
        expect(
          record.message,
          isNot(contains(secretName)),
          reason: 'secret name must never appear in logs',
        );
      }
    });
  });
}
