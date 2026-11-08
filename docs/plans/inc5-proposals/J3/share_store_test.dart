import 'dart:io';

import 'package:libreshare_core/src/model/share_models.dart';
import 'package:libreshare_core/src/share/share_store.dart';
import 'package:test/test.dart';

void main() {
  group('ShareStore Unit Tests', () {
    late Directory tempDir;
    late ShareStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('share_store_test_');
      store = ShareStore(storageDirectory: tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('saves and retrieves ShareRecord by shareId', () async {
      final record = ShareRecord(
        shareId: 'share_001',
        token: 'token_001',
        maxReceivers: 1,
        createdAtUnixSeconds: 1700000000,
        expiresAtUnixSeconds: 1700003600,
        totalBytes: 1048576,
        fileNames: ['photo.jpg'],
      );

      await store.saveShare(record);

      final retrieved = await store.getShare('share_001');
      expect(retrieved, isNotNull);
      expect(retrieved!.shareId, equals('share_001'));
      expect(retrieved.token, equals('token_001'));
      expect(retrieved.totalBytes, equals(1048576));
      expect(retrieved.fileNames, equals(['photo.jpg']));
    });

    test('listShares returns all saved records', () async {
      final r1 = ShareRecord(
        shareId: 'share_A',
        token: 'token_A',
        maxReceivers: 1,
        createdAtUnixSeconds: 1700000000,
        totalBytes: 100,
        fileNames: ['a.txt'],
      );
      final r2 = ShareRecord(
        shareId: 'share_B',
        token: 'token_B',
        maxReceivers: 2,
        createdAtUnixSeconds: 1700001000,
        totalBytes: 200,
        fileNames: ['b.txt'],
      );

      await store.saveShare(r1);
      await store.saveShare(r2);

      final all = await store.listShares();
      expect(all.length, equals(2));
      expect(all.map((e) => e.shareId).toSet(), equals({'share_A', 'share_B'}));
    });

    test('removeShare deletes record from disk', () async {
      final record = ShareRecord(
        shareId: 'share_del',
        token: 'token_del',
        maxReceivers: 1,
        createdAtUnixSeconds: 1700000000,
        totalBytes: 100,
        fileNames: ['del.txt'],
      );

      await store.saveShare(record);
      expect(await store.getShare('share_del'), isNotNull);

      await store.removeShare('share_del');
      expect(await store.getShare('share_del'), isNull);
    });

    test(
      'sweepExpired removes expired records and keeps active records',
      () async {
        final expired = ShareRecord(
          shareId: 'share_exp',
          token: 'token_exp',
          maxReceivers: 1,
          createdAtUnixSeconds: 1000,
          expiresAtUnixSeconds: 2000,
          totalBytes: 100,
          fileNames: ['exp.txt'],
        );

        final active = ShareRecord(
          shareId: 'share_act',
          token: 'token_act',
          maxReceivers: 1,
          createdAtUnixSeconds: 1000,
          expiresAtUnixSeconds: 5000,
          totalBytes: 100,
          fileNames: ['act.txt'],
        );

        await store.saveShare(expired);
        await store.saveShare(active);

        // Current time is 3000 (after 2000, before 5000)
        final now = DateTime.fromMillisecondsSinceEpoch(3000 * 1000);
        final swept = await store.sweepExpired(now);

        expect(swept, equals(1));
        expect(await store.getShare('share_exp'), isNull);
        expect(await store.getShare('share_act'), isNotNull);
      },
    );

    test(
      'security rule: stored file never contains rootKey k or raw secret',
      () async {
        final record = ShareRecord(
          shareId: 'share_sec',
          token: 'token_sec',
          maxReceivers: 1,
          createdAtUnixSeconds: 1700000000,
          totalBytes: 100,
          fileNames: ['secret.txt'],
        );

        await store.saveShare(record);

        // Read raw files in tempDir
        final files = tempDir.listSync();
        for (final f in files.whereType<File>()) {
          final content = await f.readAsString();
          expect(content.contains('rootKey'), isFalse);
          expect(content.contains('keyB64'), isFalse);
        }
      },
    );
  });
}
