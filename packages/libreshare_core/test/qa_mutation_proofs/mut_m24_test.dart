// Proof for mutant M24: a resume sidecar written for another file size (same chunk count) is discarded.
import 'dart:io';

import 'package:libreshare_core/src/transfer/resume_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('size change with equal chunk count -> not resumed', () async {
    final tmp = Directory.systemTemp.createTempSync('ls_m24_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final partial = File(p.join(tmp.path, 'a.bin.lspart'));
    const ck = 64 * 1024;
    final sha = 'ab' * 32;
    final mod = DateTime.utc(2026, 10, 30);
    final s = await ResumeStore.open(
      partialFile: partial,
      size: 10 * ck,
      chunkSize: ck,
      chunkCount: 10,
      sha256: sha,
      modified: mod,
    );
    await s.markReceived(0);
    await s.flush();
    final raf = partial.openSync(mode: FileMode.write);
    raf.truncateSync(ck);
    raf.closeSync();
    final same = await ResumeStore.open(
      partialFile: partial,
      size: 10 * ck,
      chunkSize: ck,
      chunkCount: 10,
      sha256: sha,
      modified: mod,
    );
    expect(same.resumed, isTrue, reason: 'positive control');
    final other = await ResumeStore.open(
      partialFile: partial,
      size: 10 * ck - 1,
      chunkSize: ck,
      chunkCount: 10,
      sha256: sha,
      modified: mod,
    );
    expect(other.resumed, isFalse);
  });
}
