import 'dart:convert';
import 'dart:io';

import '../model/share_models.dart';

class ShareStore {
  final Directory storageDirectory;

  ShareStore({required this.storageDirectory});

  File _fileForShare(String shareId) =>
      File('${storageDirectory.path}/share_$shareId.json');

  Future<void> saveShare(ShareRecord record) async {
    if (!await storageDirectory.exists()) {
      await storageDirectory.create(recursive: true);
    }
    final file = _fileForShare(record.shareId);
    final jsonStr = jsonEncode(record.toJson());
    await file.writeAsString(jsonStr, flush: true);
  }

  Future<ShareRecord?> getShare(String shareId) async {
    final file = _fileForShare(shareId);
    if (!await file.exists()) return null;
    try {
      final jsonStr = await file.readAsString();
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      return ShareRecord.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  Future<List<ShareRecord>> listShares() async {
    if (!await storageDirectory.exists()) return [];
    final records = <ShareRecord>[];
    await for (final entity in storageDirectory.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final map = jsonDecode(content) as Map<String, dynamic>;
          records.add(ShareRecord.fromJson(map));
        } catch (_) {}
      }
    }
    return records;
  }

  Future<void> removeShare(String shareId) async {
    final file = _fileForShare(shareId);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<int> sweepExpired(DateTime now) async {
    final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
    final all = await listShares();
    var count = 0;
    for (final share in all) {
      if (share.expiresAtUnixSeconds != null &&
          share.expiresAtUnixSeconds! < nowSeconds) {
        await removeShare(share.shareId);
        count++;
      }
    }
    return count;
  }
}
